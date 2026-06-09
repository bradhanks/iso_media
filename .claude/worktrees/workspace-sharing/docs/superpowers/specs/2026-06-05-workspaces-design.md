# Workspaces — design

**Date:** 2026-06-05
**Status:** Approved design, pre-implementation
**Scope:** v1 — solo workspaces + sidebar switcher. Sharing/collaborators is a
deferred fast-follow (out of scope here).

## Summary

A **Workspace** is a lightweight, user-created container that groups a user's
reviews — the Notion/Attio "workspaces" model. Every account has a default
**Personal** workspace and can create more. A switcher at the top of the app
sidebar lets the user create a workspace or switch the active one; the active
workspace is encoded **in the URL** (`/w/:workspace_id/…`), so reviews are
scoped to it and browser tabs stay isolated.

This is a **new, standalone layer**, deliberately orthogonal to the existing
enterprise `Organizations` concept. Organizations are the heavyweight tenant
(SSO/SCIM/enterprise billing/credit pool); individuals don't create or switch
them. Workspaces are the light, user-owned, switchable layer. The two do not
interact in v1.

### Naming note

The codebase already has a `WorkspaceLive` reading-room at `/workspace/:id`.
To avoid collision, this feature:
- names the domain layer `PerfectPaper.Workspaces` / `Workspaces.Workspace`
  (domain) — distinct from the web layer;
- moves the reading room under the new URL prefix as `/w/:workspace_id/review/:id`;
- **renames the web module `WorkspaceLive` → `ReadingRoomLive`** (and its
  collocated template) as part of v1. The route is already moving, so renaming
  now removes the "workspace means two things" cognitive overhead rather than
  leaving it for a future developer. Internal references (router, tests) update
  with it.

## Non-goals (v1)

- Inviting collaborators / workspace membership / roles / permissions.
- A credits-sharing policy (each user's reviews charge their own credits, as today).
- Bringing enterprise/group-owned sessions into the workspace switcher. Those
  remain on their existing surfaces. **Known limitation:** the workspace-scoped
  Reviews list shows only the user's own (user-owned) reviews in that workspace;
  shared/enterprise reviews are not workspace-scoped yet.
- Pandoc export hardening (timeouts, size caps) — tracked separately (see Risks).

## Data model

### New table: `workspaces`

| column        | type      | notes                                            |
|---------------|-----------|--------------------------------------------------|
| `id`          | binary_id | PK                                               |
| `name`        | string    | required, 1..120 chars                           |
| `user_id`     | binary_id | FK → users, **ON DELETE CASCADE**, the owner     |
| `is_personal` | boolean   | default false; exactly one per user is `true`    |
| timestamps    |           | utc_datetime                                     |

Indexes: `user_id`; partial unique index on `(user_id) WHERE is_personal` so a
user has at most one Personal workspace.

### `history_sessions` — add column

- `workspace_id` binary_id, FK → workspaces, **ON DELETE RESTRICT** (a workspace
  with reviews can't be hard-deleted out from under them; `delete_workspace`
  reassigns reviews to Personal first — see context API). Nullable (group/
  enterprise-owned sessions stay `NULL`).
- Index: `workspace_id`.

### `users` — add column

- `active_workspace_id` binary_id, FK → workspaces, **ON DELETE SET NULL**.
  This is a **last-used default only** — used to pick a landing workspace when a
  request arrives without one in the URL. It is **never** the live source of
  truth for the active workspace (that is the URL). `SET NULL` also breaks the
  user↔workspace deletion cycle.

### Why not reuse Organizations or Groups

- **Organizations**: heavyweight enterprise tenant; an individual can't create/
  switch them. Mapping workspace→org reintroduces exactly the coupling the
  feature must avoid.
- **Groups**: a Group must belong to an Organization (`organization_id NOT NULL`),
  which would force a synthetic org behind every individual account. Rejected.

## Context API — `PerfectPaper.Workspaces`

The sole Repo/IO boundary for workspaces. Schema carries its own changesets
(`Workspaces.Workspace`). Business-readable names.

```
@spec list_workspaces(User.t()) :: [Workspace.t()]
  # The user's workspaces, Personal pinned first, then by name.

@spec personal_workspace(User.t()) :: Workspace.t()
  # Ensure-and-return the user's Personal workspace (lazy create if absent).
  # MUST be concurrency-safe: two parallel first-requests for a new user both
  # see no Personal workspace and both try to insert, so the second loses to the
  # partial unique index. Implementation: get_by → if missing, attempt insert and
  # on a unique-constraint error re-read the winner (rescue/return existing).
  # NOTE: the index is partial — `(user_id) WHERE is_personal` — so an
  # `on_conflict` `conflict_target: [:user_id, :is_personal]` will NOT infer it;
  # the rescue-and-re-read form is used precisely to avoid that pitfall.

@spec get_workspace(id, User.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  # Scoped fetch — only returns a workspace the user owns (hides existence).

@spec create_workspace(User.t(), map()) ::
        {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  # Create a non-personal workspace owned by the user.

@spec rename_workspace(Workspace.t(), User.t(), String.t()) ::
        {:ok, Workspace.t()} | {:error, term()}
  # Rename (Personal included). Ownership enforced.

@spec delete_workspace(Workspace.t(), User.t()) ::
        {:ok, Workspace.t()} | {:error, :personal | :not_found | term()}
  # Delete a NON-personal workspace; its reviews are reassigned to the user's
  # Personal workspace first, in one Ecto.Multi. Personal can't be deleted.
  # Reassignment is a single set-based UPDATE. Verified safe: this codebase has
  # no Ecto changeset lifecycle callbacks on sessions, domain events fire only
  # via explicit Events.emit in context functions (nothing subscribes to
  # workspace reassignment), and there is no search index — so a bulk UPDATE
  # bypasses nothing. Batch only if a single user ever holds an unreasonable
  # number of reviews (not a realistic v1 concern).

@spec set_active(User.t(), workspace_id) ::
        {:ok, User.t()} | {:error, :not_found}
  # Persist the last-used default (must own the workspace). Used by the on_mount
  # hook after resolving the URL workspace; NOT the live source of truth.

```

Personal creation is owned entirely by `personal_workspace/1` (lazy, race-safe);
no other context composes a workspace changeset.

Ownership rule (v1): every function authorizes on `workspace.user_id ==
user.id`. No membership/roles yet.

## Active-workspace resolution + routing

**The URL is the source of truth.** Workspace-scoped surfaces live under a
`/w/:workspace_id` prefix inside the authenticated `live_session`:

- `/w/:workspace_id/reviews`  → `HistoryLive.Index` (the Reviews list)
- `/w/:workspace_id/new`      → `NewLive`
- `/w/:workspace_id/review/:id` → the review reading room (`ReadingRoomLive`,
  renamed from `WorkspaceLive`).
  The review's own `workspace_id` is authoritative: if it doesn't match the URL
  workspace, the on_mount canonicalizes by redirecting to
  `/w/:review_workspace_id/review/:id` (so a stale or hand-edited workspace in
  the URL never shows a review under the wrong workspace's breadcrumb).

Account-level surfaces stay **global** (not workspace-scoped):
`/account`, `/billing`, `/earn`, `/users/settings`, `/webhooks`, `/orgs/*`.

**`on_mount` hook** (`:assign_workspace`) runs on **every** authenticated route —
both workspace-scoped (`/w/:workspace_id/…`) and global (`/account`, `/billing`,
`/earn`, `/users/settings`, …) — because the sidebar switcher and its nav links
render on all of them and therefore need `@current_workspace` + `@workspaces`
assigned unconditionally. The hook has two modes:

*Scoped mode* (params include `:workspace_id`):
1. `Workspaces.get_workspace(id, user)` — if `{:error, :not_found}`, redirect to
   the user's last-used/Personal workspace (hides existence, never 500s).
2. Assign `@current_workspace` = that workspace; `@workspaces` = the full list.
3. Fire-and-forget `Workspaces.set_active(user, id)` to update the last-used
   default.

*Global mode* (no `:workspace_id` in params):
1. Resolve `@current_workspace` from the user's `active_workspace_id`, falling
   back to `Workspaces.personal_workspace(user)`. The page is **not** "in" a
   workspace — this only feeds the switcher's display and the nav-link targets
   (e.g. the "Reviews" item points at `/w/#{@current_workspace.id}/reviews`).
2. Assign `@workspaces` = the full list.

Either way, `@current_workspace` and `@workspaces` are guaranteed present
wherever `AppShell.app` renders, so the sidebar never raises for a missing assign.

`Accounts.Scope` is **not** modified — workspace context is resolved in the web
layer via the `Workspaces` context, keeping `Scope` free of a cross-context
dependency.

**Bare-URL redirect:** `/reviews` and `/new` (no `:workspace_id`) are handled by
a thin `WorkspaceRedirectController` (a plain controller, not a LiveView): it
resolves the user's last-used workspace (falling back to Personal via
`Workspaces.personal_workspace/1`) and 302s to the `/w/:id/…` equivalent. This
keeps old bookmarks and the post-login landing target working, and the
post-auth redirect points at `/reviews`.

**Switching** = `push_navigate` to the current page under the chosen
`/w/:id/…`. No hidden DB-state flip; each tab's workspace is whatever its URL
says, so tabs are isolated and links are bookmarkable.

## Switcher UX — `WorkspaceSwitcher` LiveComponent

Replaces the brand block at the top of the sidebar (`app_shell.ex` brand header).
Every signed-in page renders through `AppShell.app` and is a LiveView, so one
LiveComponent covers the whole app.

- **Trigger:** small square workspace avatar (first initial, tinted) + active
  workspace name + chevron. Collapsed icon-rail: avatar only; dropdown still opens.
- **Dropdown:**
  - list of `@workspaces`, a check on the active one → click switches
    (`push_navigate` to `/w/:id/reviews`);
  - a **"+ New workspace"** row → inline name field → `create_workspace` →
    navigate into the new workspace;
  - footer keeps the **PerfectPaper** wordmark so brand identity isn't lost.
- Rename is reachable from the dropdown (inline edit on a workspace row, or a
  small "Rename" affordance); delete (non-Personal) likewise, with a confirm.
- daisyUI semantic classes + the paper theme; no emoji; sentence case.

## Reviews scoping + nav rename

- **Sidebar nav:** the "History" item's label becomes **"Reviews"** and points at
  `/w/:current/reviews`. Route module unchanged (`HistoryLive.Index`).
- **`HistoryLive.Index`:** lists sessions for the active workspace via a new
  `workspace_id:` option on `History.list_session_summaries/2`
  (`where s.workspace_id == ^id`).
- **`NewLive`:** sets `workspace_id: @current_workspace.id` in the
  `History.begin_session/1` attrs. `Session.create_changeset` casts `workspace_id`.

## Registration / lifecycle

**No registration code changes.** Personal workspaces are created **lazily** and
uniformly via the race-safe `Workspaces.personal_workspace/1`, called by the
`:assign_workspace` on_mount hook the first time any authenticated page resolves
a workspace. This covers *every* account-creation path identically — normal
sign-up, SSO JIT, guest/magic-link, SCIM — with a single code path, and avoids
weaving a Multi through `Accounts.register_user/1`'s several branches (guest
promotion / SSO / normal).

A brand-new user simply has `active_workspace_id: nil` until their first
authenticated page load, at which point global-mode resolution falls back to
`personal_workspace/1` (which creates + returns Personal). Existing users are
handled by the backfill. Because `personal_workspace/1` is concurrency-safe,
parallel first-requests converge on one Personal workspace.

## Migration / backfill

Split to keep the schema change non-blocking:

- **Migration A (schema, fast):** `ADD COLUMN`s + FKs + indexes, all nullable, no
  data writes.
- **Migration B (backfill, set-based SQL — no iterative loop):**
  1. `INSERT INTO workspaces (…) SELECT …` — one Personal workspace per existing
     user.
  2. `UPDATE history_sessions s SET workspace_id = w.id FROM workspaces w WHERE
     w.user_id = s.owner_id AND s.owner_type = 'user' AND s.workspace_id IS NULL`.
  3. `UPDATE users u SET active_workspace_id = w.id FROM workspaces w WHERE
     w.user_id = u.id AND w.is_personal`.

Escape hatch (only if row counts ever warrant it): run step 2 in chunks of N ids
outside one transaction. Not needed at current scale.

## Testing

- **`Workspaces` context:** create / rename / `personal_workspace` ensures-once /
  `delete_workspace` reassigns reviews to Personal & refuses Personal / ownership
  rejection (another user's workspace → `:not_found`).
- **`History`:** `workspace_id` set on `begin_session`; `list_session_summaries`
  filters by `workspace_id`.
- **Lazy creation:** a fresh user's first authenticated page load creates and
  returns their Personal workspace via `personal_workspace/1`.
- **Routing / on_mount:** visiting another user's `/w/:id/reviews` redirects (no
  500); bare `/reviews` redirects to `/w/:last/reviews`.
- **Global-page sidebar:** a global page (`/account`) assigns `@current_workspace`
  + `@workspaces` and renders the switcher + a "Reviews" link to
  `/w/:current/reviews` (no missing-assign crash).
- **Concurrent lazy create:** two parallel `personal_workspace/1` calls for a
  fresh user yield the same single workspace, no `Ecto.ConstraintError`.
- **Switcher LiveComponent:** renders the user's workspaces, switch navigates to
  `/w/:id/reviews`, create makes a workspace and navigates into it.
- **Multi-tab isolation:** two workspaces at two URLs; creating a review under
  one URL does not appear under the other (URL is source of truth).
- **`NewLive`:** a new review lands in the URL's workspace.

## Risks / follow-ups (out of this spec)

- **Pandoc DoS / timeout:** panpipe's pandoc port (`pandoc.ex` `Exile.stream!`)
  has no timeout, and export/ingest have no size caps. File a hardening ticket
  (port timeout + upload/export size limits) against the export/ingest path.
  (Pandoc is already a hard runtime dependency via ingestion, so deploy already
  ships the binary — not introduced by this feature.)
- **Sharing/collaborators:** the deferred fast-follow — workspace membership +
  roles, members seeing a workspace's reviews, and the credits policy for shared
  reviews. The schema (`workspaces` + `workspace_id`) is built to extend into it.
- **Git hygiene:** branches `revert/workspace-redesign` + `revert/workspace-v2`
  hold the only copy of an unrelated session's commit `db44a76`; that session
  must cherry-pick it before the branches are deleted.
