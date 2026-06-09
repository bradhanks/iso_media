# Collaborative Commenting + External Guests — Implementation Plan (Spec 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Human (collaborator) comments with authorship + threading on top of AI feedback, plus an invite flow (existing users + external email magic-link guests) granting scoped access via the Spec 1 `resource_grants` primitive, with REST + LiveView surfaces and a `comment.added` event.

**Architecture:** `comments` gains `author_type`/`author_id`/`body`/`parent_id`. `History.add_comment` is `:comment`-gated via `Authz.permit?` and emits `comment.added` post-commit. Grant writes go through a new `Authz.grant_access/revoke_access/list_grants` (gated by `:share`). `History.invite_to_session` resolves an existing user or an email→magic-link guest (`Accounts.find_or_create_guest`) and grants access. Reuses Spec 1 (grants/authz), Spec 8 (Events bus), and the existing magic-link auth.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto/Postgres. Spec: `docs/superpowers/specs/2026-06-02-collaborative-commenting-design.md`.

## Conventions
Architecture laws; `@spec`/`@doc`/`@type`; post-commit `Events.emit` (never in a Multi); grant writes inside `Authz`; LiveView quality bar (discrete test ids, daisyUI semantic classes, no emoji, no `raw`). `TODO(collab)` for deferred items.

---

## Task 1: Comment authorship + threading (schema)

**Files:** migration `priv/repo/migrations/20260602130000_add_comment_authorship.exs`; modify `lib/perfect_paper/history/comment.ex`; tests.

- [ ] **Step 1 — migration:**
```elixir
defmodule PerfectPaper.Repo.Migrations.AddCommentAuthorship do
  use Ecto.Migration

  def up do
    alter table(:comments) do
      add :author_type, :string
      add :author_id, :binary_id
      add :body, :text
      add :parent_id, references(:comments, type: :binary_id, on_delete: :nilify_all)
    end

    execute "UPDATE comments SET author_type = 'ai' WHERE author_type IS NULL"
    alter table(:comments), do: modify(:author_type, :string, null: false)
    create index(:comments, [:parent_id])
  end

  def down do
    drop index(:comments, [:parent_id])
    alter table(:comments) do
      remove :author_type
      remove :author_id
      remove :body
      remove :parent_id
    end
  end
end
```

- [ ] **Step 2 — failing tests** (`test/perfect_paper/history/comment_test.exs`, create if absent): `create_changeset` (AI) sets `author_type: :ai`; `author_changeset` requires `session_id`+`author_id`+`body`, sets `author_type: :user`; `author_changeset` accepts a `parent_id`; an unknown `author_type` is impossible (enum).

- [ ] **Step 3 — schema.** In `lib/perfect_paper/history/comment.ex`: add to the schema (after `:position`):
```elixir
    field :author_type, Ecto.Enum, values: [:ai, :user], default: :ai
    field :author_id, :binary_id
    field :body, :string
    field :parent_id, :binary_id
```
Update `create_changeset/2` (AI) to also `put_change(:author_type, :ai)` (or cast it) so AI comments are explicitly authored. Add:
```elixir
  @doc "Builds a human collaborator comment (top-level or a reply via parent_id)."
  @spec author_changeset(t(), map()) :: Ecto.Changeset.t()
  def author_changeset(comment, attrs) do
    comment
    |> cast(attrs, [:session_id, :author_id, :body, :parent_id])
    |> validate_required([:session_id, :author_id, :body])
    |> put_change(:author_type, :user)
  end
```

- [ ] **Step 4 — migrate + run PASS.** `mix compile --warnings-as-errors` clean.
- [ ] **Step 5 — commit:** `git add -A && git commit -m "feat(history): comment authorship + threading (author_type/author_id/body/parent_id)"`

---

## Task 2: `History.add_comment` + `comment.added` event

**Files:** modify `lib/perfect_paper/events/event.ex` (add type); `lib/perfect_paper/history.ex`; tests.

- [ ] **Step 1 — add event type.** In `lib/perfect_paper/events/event.ex`, add `comment.added` to the `@types` list (`~w(... comment.added)a`).
- [ ] **Step 2 — failing tests** (append to `history_test.exs`): a `:commenter`-grantee can `add_comment` (assert the comment is author_type :user, author_id set); a user with no line of sight → `{:error, :not_found}`; a `:viewer`-grantee → `{:error, :unauthorized}`; a reply sets `parent_id`; a `parent_id` from a DIFFERENT session is rejected (`{:error, :invalid_parent}` or changeset); emits `comment.added` (subscribe via `Events.subscribe(:"comment.added")`). Use `AuthzFixtures.session_grant_fixture/3` to grant roles.
- [ ] **Step 3 — implement** in `lib/perfect_paper/history.ex`:
```elixir
  @doc "Adds a human comment to a session (requires :comment). Optional parent_id replies to another comment in the same session."
  @spec add_comment(Ecto.UUID.t(), Scope.t(), map()) :: {:ok, Comment.t()} | {:error, term()}
  def add_comment(session_id, %Scope{} = scope, attrs) do
    with %Session{} = session <- Repo.get(Session, session_id),
         :ok <- Authz.permit?(scope, :comment, session),
         :ok <- validate_parent(attrs[:parent_id] || attrs["parent_id"], session_id),
         {:ok, comment} <-
           %Comment{}
           |> Comment.author_changeset(Map.merge(stringify?(attrs), %{"session_id" => session_id, "author_id" => scope.user.id}))
           |> Repo.insert() do
      _ =
        Events.emit(:"comment.added", %{
          organization_id: session.organization_id,
          actor_id: scope.user.id,
          resource: %{type: :comment, id: comment.id},
          data: %{session_id: session_id, parent_id: comment.parent_id}
        })

      {:ok, comment}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_parent(nil, _session_id), do: :ok
  defp validate_parent(parent_id, session_id) do
    case Repo.one(from c in Comment, where: c.id == ^parent_id and c.session_id == ^session_id, select: 1) do
      nil -> {:error, :invalid_parent}
      _ -> :ok
    end
  end
```
(Add `alias PerfectPaper.Events` to history.ex if not present — it was added in Spec 8 Task 6, confirm. Handle attrs key-type consistently — use a small normalizer; mirror how other History fns take maps.)
- [ ] **Step 4 — run PASS; compile clean; commit:** `git add -A && git commit -m "feat(history): add_comment (authz-gated) + comment.added event; same-session parent validation"`

---

## Task 3: `Authz` grant write API

**Files:** modify `lib/perfect_paper/authz.ex`; tests (`authz_test.exs`).

- [ ] **Step 1 — failing tests:** `grant_access(scope, {:session, id}, {:user, uid}, :commenter)` — owner/admin succeeds (grant created, role correct); re-grant updates the role (upsert, no dup); non-admin/`:viewer` → `{:error, :unauthorized}`. `revoke_access` removes it (gated). `list_grants` returns the resource's grants (gated). Use sessions (user-owned by the caller → owner clears :share) + a grantee.
- [ ] **Step 2 — implement** in `lib/perfect_paper/authz.ex` (uses `ResourceGrant`, already aliased):
```elixir
  @doc "Grants `role` on `resource` to `subject`. Requires :share on the resource. Upserts (re-grant updates role)."
  @spec grant_access(Scope.t(), {:session, Ecto.UUID.t()}, {:user | :group, Ecto.UUID.t()}, Role.t()) ::
          {:ok, ResourceGrant.t()} | {:error, term()}
  def grant_access(%Scope{} = scope, {:session, sid} = _resource, {subject_type, subject_id}, role) do
    with %Session{} = session <- Repo.get(Session, sid),
         :ok <- permit?(scope, :share, session) do
      %ResourceGrant{}
      |> ResourceGrant.create_changeset(%{resource_type: :session, resource_id: sid, subject_type: subject_type, subject_id: subject_id, role: role, granted_by: scope.user.id})
      |> Repo.insert(
        on_conflict: [set: [role: role]],
        conflict_target: [:resource_type, :resource_id, :subject_type, :subject_id]
      )
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Revokes `subject`'s grant on `resource`. Requires :share."
  @spec revoke_access(Scope.t(), {:session, Ecto.UUID.t()}, {:user | :group, Ecto.UUID.t()}) :: :ok | {:error, term()}
  def revoke_access(%Scope{} = scope, {:session, sid}, {subject_type, subject_id}) do
    with %Session{} = session <- Repo.get(Session, sid),
         :ok <- permit?(scope, :share, session) do
      {n, _} =
        Repo.delete_all(
          from g in ResourceGrant,
            where: g.resource_type == :session and g.resource_id == ^sid and g.subject_type == ^subject_type and g.subject_id == ^subject_id
        )
      if n > 0, do: :ok, else: {:error, :not_found}
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end

  @doc "Lists grants on `resource`. Requires :share."
  @spec list_grants(Scope.t(), {:session, Ecto.UUID.t()}) :: {:ok, [ResourceGrant.t()]} | {:error, term()}
  def list_grants(%Scope{} = scope, {:session, sid}) do
    with %Session{} = session <- Repo.get(Session, sid),
         :ok <- permit?(scope, :share, session) do
      {:ok, Repo.all(from g in ResourceGrant, where: g.resource_type == :session and g.resource_id == ^sid)}
    else
      nil -> {:error, :not_found}
      err -> err
    end
  end
```
(Confirm `ResourceGrant.create_changeset` exists with those fields — it does, Spec 1. The unique index `resource_grants_unique_index` backs the upsert conflict_target.)
- [ ] **Step 3 — run PASS; compile clean; commit:** `git add -A && git commit -m "feat(authz): grant_access/revoke_access/list_grants (share-gated grant writes)"`

---

## Task 4: Guest onboarding + `History.invite_to_session`

**Files:** modify `lib/perfect_paper/accounts.ex` (find_or_create_guest); `lib/perfect_paper/history.ex` (invite_to_session); a notifier (`lib/perfect_paper/history/notifier.ex` or reuse existing); tests.

- [ ] **Step 1 — `Accounts.find_or_create_guest/1`.** Read `register_user/1` + `get_user_by_email/1`. Add:
```elixir
  @doc "Finds a user by email, or creates a passwordless guest (email-only, no org). Returns {:ok, user}."
  @spec find_or_create_guest(String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_guest(email) do
    case get_user_by_email(email) do
      %User{} = user -> {:ok, user}
      nil -> register_user(%{email: email})
    end
  end
```
(Match `register_user/1`'s expected attrs shape — read it; it's the email-only magic-link signup.)
- [ ] **Step 2 — failing tests** (`history_test.exs`): `invite_to_session(session, owner_scope, "guest@example.com", :commenter)` → creates a guest user (no org membership) + a `:commenter` grant + the guest can then `permit?(:comment)`; inviting an existing `%User{}` → grant only; a non-owner/non-admin → `{:error, :unauthorized}`; emits `session.shared`. Assert `Accounts.find_or_create_guest` produced a user and a magic-link/invite email was delivered (use the test mailer assertion pattern from existing email tests — check how the repo asserts delivered emails, e.g. `assert_email_sent` or the Swoosh test adapter).
- [ ] **Step 3 — implement `History.invite_to_session/4`:**
```elixir
  @doc "Invites a recipient (email or %User{}) to collaborate on a session (default :commenter). Requires :share."
  @spec invite_to_session(Session.t(), Scope.t(), String.t() | map(), Role.t()) :: {:ok, map()} | {:error, term()}
  def invite_to_session(%Session{} = session, %Scope{} = scope, recipient, role \\ :commenter) do
    with {:ok, user, guest?} <- resolve_recipient(recipient),
         {:ok, grant} <- Authz.grant_access(scope, {:session, session.id}, {:user, user.id}, role) do
      if guest?, do: deliver_session_invite(user, session, scope)
      _ = Events.emit(:"session.shared", %{organization_id: session.organization_id, actor_id: scope.user.id, resource: %{type: :session, id: session.id}, data: %{invited_user_id: user.id}})
      {:ok, %{user: user, grant: grant}}
    end
  end

  defp resolve_recipient(%{id: _} = user), do: {:ok, user, false}
  defp resolve_recipient(email) when is_binary(email) do
    case Accounts.find_or_create_guest(email) do
      {:ok, user} -> {:ok, user, true}   # treat email-invited as guest (deliver magic link)
      err -> err
    end
  end
```
`deliver_session_invite/3`: send a magic-link via `Accounts.deliver_login_instructions(user, &magic_url_with_redirect/1)` where the URL carries a safe internal `redirect_to` of the session view (e.g. `~p"/history/#{session.id}"`), PLUS/OR a `History.Notifier.deliver_session_invitation(user, session, inviter)`. Use the existing magic-link delivery; read `deliver_login_instructions/2`'s url-fun contract. (Add `alias PerfectPaper.Accounts` to history.ex if needed.)
- [ ] **Step 4 — run PASS; compile clean; commit:** `git add -A && git commit -m "feat(history): invite_to_session (existing user + email magic-link guest) + Accounts.find_or_create_guest"`

---

## Task 5: Magic-link safe redirect to the shared session

**Files:** `lib/perfect_paper_web/controllers/user_session_controller.ex` (+ wherever the magic-link URL/redirect is handled); test.

- [ ] **Step 1 — read** the magic-link login path (`user_session_controller.ex` `create` magic-link branch at ~line 65, `login_user_by_magic_link`). Determine how a post-login redirect is chosen (`UserAuth.log_in_user` likely honors a `return_to`/`user_return_to` session key).
- [ ] **Step 2 — failing test:** logging in via magic-link with a `redirect_to` of an INTERNAL session path lands there; an EXTERNAL/unsafe `redirect_to` is ignored (falls back to the default). 
- [ ] **Step 3 — implement:** accept a `redirect_to` param on the magic-link login; validate it's a safe INTERNAL path (starts with `/`, no `//` or scheme — reuse/define a `safe_path?/1`); stash it as the `user_return_to` (the mechanism `UserAuth.log_in_user` already uses) so the guest lands on the shared session. If the magic-link flow already supports `user_return_to`, just thread `redirect_to` into it; otherwise add the minimal safe handling. Do NOT introduce an open-redirect.
- [ ] **Step 4 — run PASS; commit:** `git add -A && git commit -m "feat(auth): magic-link honors a safe internal redirect_to (guest lands on the shared session)"`

(If, on reading, the existing flow already cleanly supports a safe return path with no change needed, write a test proving it and note that in the report — skip the code change.)

---

## Task 6: REST — add-comment + invitation endpoints + JSON author fields

**Files:** `history_controller.ex`, `history_json.ex`, `api/schemas.ex` (OpenAPI), router; tests.

- [ ] **Step 1 — JSON.** In `history_json.ex` `comment_map/1`, add `author_type`, `author_id`, `body`, `parent_id` to the rendered map.
- [ ] **Step 2 — controller actions** (thin → History; `scope(conn)`; OpenAPI `operation` annotations, tag "History", security bearer/apiKey, mirroring existing actions):
  - `add_comment` (POST `/api/history/:id/comments`): `History.add_comment(id, scope, params)` → 201 `:comment` render. (`:comment`-gated → 403/404 via fallback.)
  - `invite` (POST `/api/history/:id/invitations`): resolve the session (`History.get_session(id, scope)` → nil→404), then `History.invite_to_session(session, scope, params["email"] || %{id: params["user_id"]}, role_from(params))` → 201 a small invitation render (granted user id + role; NO secret). owner/admin-gated → 403.
- [ ] **Step 3 — routes** in the authed `/api` scope: `post "/history/:id/comments", HistoryController, :add_comment` and `post "/history/:id/invitations", HistoryController, :invite`.
- [ ] **Step 4 — OpenAPI.** Update the `Comment` schema in `api/schemas.ex` with the new author fields; add `AddCommentRequest`, `InvitationRequest`, `Invitation` schemas; annotate the two new actions. Extend the api_docs coverage test with the new paths.
- [ ] **Step 5 — tests** (`history_controller_test.exs`): a commenter-grantee POSTs a comment → 201 with author fields; a viewer → 403; the owner invites by email → 201 (+ a guest user exists); a non-owner invite → 403. Run PASS; api_docs test green.
- [ ] **Step 6 — commit:** `git add -A && git commit -m "feat(api): add-comment + invitation REST endpoints (OpenAPI); comment author fields in JSON"`

---

## Task 7: LiveView — threaded comments + composer + collaborators panel

**Files:** `lib/perfect_paper_web/live/history_live/show.ex` + `show.html.heex`; test.

- [ ] **Step 1 — read** `show.ex`/`show.html.heex` to match the existing structure (how it loads the session + comments, assigns, event handlers).
- [ ] **Step 2 — render comments threaded:** group by `parent_id` (top-level comments with their replies nested one level). Each comment shows author: an **AI** badge for `author_type == :ai`, else the commenter's name/email (email local-part per the spec default). Discrete ids (`comment-#{id}`, `replies-#{id}`).
- [ ] **Step 3 — composer:** for a viewer whose scope `permit?(:comment)` is `:ok` (compute on mount/assign `can_comment?`), show a comment form (top-level) + a reply affordance per comment (sets `parent_id`). `handle_event("add_comment", ...)` → `History.add_comment(session_id, scope, %{body: ..., parent_id: ...})` → reload comments; handle `{:error, _}` with a flash (no crash).
- [ ] **Step 4 — collaborators panel:** if `permit?(:share)` is `:ok` (owner/admin), show an invite form (email or user + role) → `History.invite_to_session` + a list of current grants (`Authz.list_grants`) with a revoke button → `Authz.revoke_access`. Discrete ids.
- [ ] **Step 5 — tests** (`show LiveView test`): owner sees the composer + collaborators panel; adding a comment renders it (discrete id); a reply nests under its parent; inviting by email shows the new grant; revoke removes it; a `:commenter` guest sees the composer but NOT the collaborators panel; a no-access user can't reach the page. Discrete-id assertions.
- [ ] **Step 6 — commit:** `git add -A && git commit -m "feat(web): threaded collaborator comments + composer + collaborators panel (LiveView)"`

---

## Task 8: Pre-merge verification
- [ ] **Step 1:** `mix compile --force --warnings-as-errors` clean; `grep -rn "TODO(collab)" lib/` lists deferred items.
- [ ] **Step 2:** `mix precommit` fully green (incl. the new comment/invite/guest/LiveView/api tests + no regression to Spec 1/8 tests). `mix format`.
- [ ] **Step 3:** commit any fixups.

---

## Self-review (authoring)
- **Spec coverage:** authorship+threading schema (T1) ✓; add_comment + comment.added (T2) ✓; grant write API (T3) ✓; guest + invite (T4) ✓; magic-link safe redirect (T5) ✓; REST + JSON + OpenAPI (T6) ✓; LiveView threaded + composer + collaborators (T7) ✓; verify (T8) ✓.
- **Reuses, not rebuilds:** grants/permit? (Spec 1), Events bus (Spec 8), magic-link/register_user/get_user_by_email/deliver_login_instructions (existing). No new auth mechanism.
- **Security:** invite/grant `:share`-gated; add_comment `:comment`-gated; parent same-session; magic-link redirect internal-only; authored (no anonymous). 
- **Post-commit emission** for comment.added/session.shared (never in a Multi).
- **Open defaults:** guest display = email local-part; reuse `session.shared` for invites (no new event) — both stated in the spec; adjust if the user objects.
