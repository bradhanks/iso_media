# Collaborative Commenting + External Guests (Spec 2) — Design

**Date:** 2026-06-02
**Status:** Draft — pending user review
**Nature:** Real feature. Adds human (collaborator) comments with authorship + threading on top of the existing AI feedback, plus an invite flow (existing users + external email guests) that grants scoped access via the Spec 1 `resource_grants` primitive and the existing magic-link auth.

## Why

The product's collaboration story: a writer invites others (co-authors, advisors, external reviewers) to read a manuscript review and leave comments — including replying to a specific piece of AI feedback. The authorization primitives already exist (Spec 1 `resource_grants`, `Authz.permit?(:comment)`, grant-aware `scope_query`); the auth primitive exists (magic-link); and the event bus exists (Spec 8). This spec wires the human-facing flow on top.

## Locked decisions (brainstorming)

| Decision | Choice |
|---|---|
| Comment model | **Threaded.** `comments` gains `author_type` (:ai\|:user), `author_id` (nil for AI), `body` (human free-text), `parent_id` (nullable self-ref → reply target). AI feedback keeps its structured fields (`original_text`/`suggestion`/`explanation`/`category`/`position`); humans post a `body`, top-level or as a reply to any comment. |
| Guest access | **Magic-link guest account.** Invite by email → find-or-create a real passwordless `User` (no org membership) + a `resource_grant` to that one session → email a magic-link. Authz already treats the guest as a subject with one scoped grant. |
| Invites | Session owner (or `:share`/admin) invites by **email OR existing user**; default grant `:commenter` (`:viewer`/`:editor` selectable). Emits `comment.added` webhooks (Spec 8 bus). |

## Architecture

### 1. Comment authorship + threading
Migration on `comments`: add `author_type :string` (default `"ai"`, NOT NULL after backfill), `author_id :binary_id` (nullable), `body :text` (nullable), `parent_id :binary_id` (nullable, self-FK → comments, on_delete `:nilify_all` so deleting a parent doesn't orphan-cascade replies). Index `[:session_id]`, `[:parent_id]`. **Backfill** existing rows to `author_type = 'ai'` (they're all AI today).

`History.Comment` schema: add the fields. `author_type` `Ecto.Enum [:ai, :user]`. Keep `create_changeset/2` for AI comments (sets `author_type: :ai`). Add `author_changeset/2` for human comments: casts `[:session_id, :author_id, :body, :parent_id]`, requires `[:session_id, :author_id, :body]`, sets `author_type: :user`. (AI comments have no `body`; human comments have no structured suggestion fields — both coexist.)

### 2. Add-comment flow (`History`)
`History.add_comment(session_id, scope, attrs)` (attrs: `body`, optional `parent_id`):
- `Authz.permit?(scope, :comment, session)` — `{:error, :not_found}` (no line of sight) / `{:error, :unauthorized}` (visible, under-roled). A `:commenter` grant clears `:comment`.
- Validate `parent_id` (if given) belongs to the same session.
- Insert via `Comment.author_changeset` (author_type :user, author_id `scope.user.id`).
- **Post-commit**, emit `:"comment.added"` (new event type) with `organization_id: session.organization_id, actor_id: scope.user.id, resource: %{type: :comment, id: comment.id}, data: %{session_id: session_id, parent_id: parent_id}`. Fans out to webhooks (org-scoped) + PubSub (so a future realtime comment stream rides the same bus).
- Returns `{:ok, comment} | {:error, ...}`.

Human comments do **not** use the AI dismiss/address lifecycle (that's the writer acting on feedback). Optional lightweight `resolve`/`unresolve` on a human thread is **out of scope this pass** (note as TODO).

### 3. Grant API (`Authz`)
`resource_grants` exists + is read by `Authz`; this adds the **write** side:
- `Authz.grant_access(scope, resource, subject, role)` — gated by `permit?(scope, :share, resource)` (owner/admin). `resource` = `{:session, id}`, `subject` = `{:user, user_id}`. Upserts the grant (unique on resource+subject; re-inviting updates the role). Returns `{:ok, grant} | {:error, :unauthorized | changeset}`. `@spec`/`@doc`.
- `Authz.revoke_access(scope, resource, subject)` — gated; deletes the grant.
- `Authz.list_grants(scope, resource)` — gated; the resource's grants (for the manage-collaborators UI).
(Keeps grant writes inside the `Authz` context that owns `ResourceGrant`.)

### 4. Invite flow (`History`)
`History.invite_to_session(session, scope, recipient, role \\ :commenter)`:
- `recipient` is an email string OR a `%User{}`/user_id.
- Resolve recipient: existing `%User{}` → use it; email → `Accounts.find_or_create_guest(email)` (NEW thin Accounts fn: `get_user_by_email/1` || `register_user/1` — passwordless, no org). A flag/derivation marks "guest" = a user with no confirmed password + only resource_grants (no membership); no schema change required this pass.
- `Authz.grant_access(scope, {:session, session.id}, {:user, user.id}, role)` (this enforces `:share`).
- If the recipient was an **email guest** (or any not-yet-active user): `Accounts.deliver_login_instructions(user, magic_link_url_fun)` where the magic-link, on login, redirects to the shared session (carry the session id as the post-login return path). Send a session-scoped invite email (reuse the magic-link delivery + a `Notifier.deliver_session_invitation/3` that names the session + inviter).
- Returns `{:ok, %{user: user, grant: grant}} | {:error, ...}`.
- Emits `:"session.shared"` (existing event) on a new grant (collaboration signal).

Magic-link redirect: the login-instructions URL fun embeds a `redirect_to` of the session view; after `login_user_by_magic_link`, the controller honors a safe internal `redirect_to`. (If the existing magic-link flow has no return-path support, add a minimal safe `redirect_to` param to the login path — internal-only validation. Documented in the plan.)

### 5. Web surface
- **REST** (`HistoryController`, OpenAPI per Spec 7):
  - `POST /api/history/:id/comments` — `add_comment` (body, parent_id); 201 the comment (with author). `:comment`-gated → 403/404 via FallbackController.
  - `POST /api/history/:id/invitations` — `invite_to_session` (email|user_id, role); owner/admin-gated. Returns the grant (no secret).
  - `GET /api/history/:id` show now includes each comment's `author_type`/`author_id`/`body`/`parent_id` (extend `HistoryJSON` + the OpenAPI `Comment` schema).
- **LiveView** (`history_live/show`): render comments grouped by thread (replies indented under their parent), each tagged with author — an **AI** badge vs the commenter's name/email. A comment composer for `:comment`-authorized viewers (reply-to sets parent_id). For the owner/admin: a **collaborators panel** — invite by email/user + role, list current grants, revoke. Discrete test ids; `paper` theme; no emoji; reduced-motion.

### 6. Events
Add `:"comment.added"` to `Events.Event` types. Emit from `add_comment` post-commit. (Webhook fan-out works for org/group-owned sessions; user-owned sessions broadcast on PubSub only — consistent with Spec 8.) `session.shared` already exists and is emitted on new grants.

## Security
- Inviting is `:share`-gated (owner/admin) — a `:commenter` guest cannot invite others or escalate.
- Guests are real users with NO org membership and a single resource_grant — `Authz` already confines them; `scope_query` only shows them the granted session.
- Magic-link `redirect_to` must be validated as an internal path (no open redirect).
- A guest's comment is attributed (`author_id`) — full audit trail (SOC 2 CC6/CC7); no anonymous authorship.
- `parent_id` validated to the same session (no cross-session reply injection).
- Re-invite upserts the grant (no duplicate-grant rows; role update is `:share`-gated).

## Testing
- Comment schema: AI `create_changeset` still works (author_type :ai); `author_changeset` requires author_id+body, sets :user; parent_id same-session validation.
- `add_comment`: a `:commenter` grantee can add (assert author + emit `comment.added` via `Events.subscribe`/`assert_enqueued`); a no-line-of-sight user → :not_found; a `:viewer` → :unauthorized; reply sets parent_id; cross-session parent rejected.
- `Authz.grant_access`/revoke/list: owner/admin can; non-admin → :unauthorized; upsert updates role.
- `invite_to_session`: existing user → grant; new email → guest user created (no membership) + grant + `deliver_login_instructions` called (assert the email) ; emits session.shared; non-owner → :unauthorized.
- REST: add-comment + invitation endpoints (gated; OpenAPI coverage extended). LiveView: comment composer, threaded render (discrete ids), collaborators panel invite/revoke, guest sees only the shared session.
- Magic-link guest end-to-end: invited email → magic-link login → lands on the session, can comment, cannot see other sessions.

## Out of scope (this pass — TODO)
- Human-comment resolve/unresolve threads (`TODO(collab)`).
- Real-time comment streaming (the `comment.added` PubSub topic is emitted; channels stay stubbed — Spec for realtime later).
- @-mentions / notifications-on-reply (could ride the bus later).
- Per-comment edit/delete history.

## Definition of done
- `comments` authorship + threading (migration + backfill + schema changesets).
- `History.add_comment` (authz-gated, post-commit `comment.added`); `Authz.grant_access`/`revoke_access`/`list_grants`; `History.invite_to_session` (existing user + email→magic-link guest); `Accounts.find_or_create_guest`.
- REST add-comment + invitation endpoints (OpenAPI); `HistoryJSON` comment author fields; LiveView threaded comments + composer + collaborators panel.
- `comment.added` event wired; magic-link invite email + safe redirect.
- Tests green; `mix precommit` green.

## Open questions
1. **Guest identity display** — show a guest's email, or a display name? Default: email local-part as the display name (no extra profile field this pass).
2. **`session.shared` vs a new `session.collaborator_invited` event** — reuse `session.shared` for new grants (simpler), or add a distinct event? Default: reuse `session.shared` (it already means "made accessible to others"); add a distinct event only if you want webhook consumers to distinguish public-toggle from invite.
