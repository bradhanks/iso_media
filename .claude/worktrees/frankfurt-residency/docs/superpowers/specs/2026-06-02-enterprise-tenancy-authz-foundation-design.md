# Enterprise Tenancy & Authorization Foundation — Design (Spec 1)

**Date:** 2026-06-02
**Status:** Approved (foundation), pending implementation plan
**Author:** brainstorming session

## Why this exists

PerfectPaper today is single-owner end to end:

- A `history_session` (a manuscript + its review) belongs to one `user_id`.
- Authorization is a **scattered ownership check** — `where s.user_id == ^user_id`
  inlined into every query in `history.ex` (this is what the recent IDOR fix
  enforced).
- `Organizations` exist only as a **flat shared credit pool** (`owner_id`,
  `credit_pool`, flat `owner|admin|member` memberships). An org does not *own*
  documents; it funds them.
- `comments` are **AI-only** — no author concept, no human commenter.

This is a B2C corner. Enterprise B2B requires: documents owned by a team (not a
person who may leave), departments nested arbitrarily deep to mirror a customer's
org chart, granular and auditable access, external collaborators who can comment,
and identity/billing that plug into Microsoft Entra. **The expensive-to-retrofit
seams are resource ownership and the authorization choke point.** Build those
correctly once, while the app is small, and the rest is additive.

## The full picture — 5-spec decomposition

This document specifies **Spec 1 only**. The others are designed-for, not built.

```
Spec 1 ─ Tenancy & Authorization Foundation   ◀── THIS DOC; everything depends on it
   │
   ├── Spec 2 ─ Collaborative commenting & guests
   ├── Spec 3 ─ Enterprise identity (Entra SSO + SCIM group-sync)
   ├── Spec 4 ─ Enterprise billing (seats/contract + per-group budgets + chargeback)
   └── Spec 5 ─ Teams/Graph hooks (notifications, OneDrive/SharePoint import)   ◀── last, optional
```

Specs 2–4 assume groups exist, resources have polymorphic owners, and a policy
choke point answers "may this subject do this?". Once Spec 1 ships those
primitives, 2/3/4 add new subjects (guests, SCIM-provisioned users), new grants,
and new attributes — **with no call-site rewrites.**

## Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Hierarchy | **Org → nested Groups**, arbitrary depth, permissions inherit **up** the tree (a role at an ancestor group applies to descendant-owned resources). Postgres **`ltree`**. |
| Resource ownership | **Polymorphic** — `owner_type ∈ {:user, :group}` + `owner_id`, with denormalized `org_id` for tenant scoping, plus per-resource **grants** for sharing. |
| Permission model | **ABAC-shaped interface, RBAC rules under the hood.** A single `Authz.permit?(subject, action, resource, env)` choke point. Pure Elixir pattern-matching — no third-party rules engine. A **decision log** records allow/deny + reason for audit. |
| Commenting (Spec 2) | Comments gain an author (`:ai` or `:user`). Commenters = members + internally-invited + external email guests. Guests are real users with a single scoped resource grant. |
| Microsoft (Spec 3) | Entra ID SSO (OIDC/SAML), SCIM 2.0 provisioning + nested group sync, later Teams/Graph hooks. All behaviour-gated. |
| Billing (Spec 4) | Org contract (seats/pool) + budget delegation down the group tree + per-group usage attribution. |

## Spec 1 scope

**In:** nested groups; polymorphic resource ownership + migration of existing
rows; resource grants; the `Authz` context + policy engine + decision log;
refactor of `History`'s inline ownership checks to route through `Authz`.

**Out (designed-for, not built):** any Microsoft code, seats/budgets/billing
structure changes, comment authorship + guest invitations (Spec 2), Teams/Graph.

## Architecture

Follows the repo's law: **one context = the only public API and the only Repo/IO
boundary.** Schemas carry their own changesets; queries inline; multi-step writes
via `Ecto.Multi`; `@spec`/`@type`/`@moduledoc` throughout.

### 1. Nested groups — `Organizations` context grows a tree

The `Organizations` context expands from "credit pool" to "tenant + org chart".

New schema `Organizations.Group`:

```
groups
  id          binary_id  pk
  org_id      binary_id  -> organizations.id   (every group belongs to one org)
  parent_id   binary_id  null -> groups.id     (null = top-level under the org)
  name        string
  path        ltree                            (materialized path of group ids)
  kind        enum [:college, :department, :team, :lab, ...]  (cosmetic label; optional)
  timestamps
```

- `path` is the **materialized `ltree` path** of ancestor group ids (e.g.
  `eng.eng_na.marketing.content`). It is maintained by the context on insert/move,
  never cast from user input.
- **GiST index on `path`** (`CREATE INDEX ... USING GIST (path)`) — required for
  ancestor/descendant (`@>`, `<@`) queries to stay fast at enterprise scale.
- Self-referential `parent_id` is kept for integrity + cheap "direct children",
  but tree traversal uses `path`, not recursive `parent_id` walks.

`Organizations.Membership` evolves: today it ties a user to an **org** with a
role. We keep org-level membership and **add group membership** — a user may hold
a role at any node in the tree:

```
group_memberships
  id        binary_id pk
  group_id  binary_id -> groups.id
  user_id   binary_id
  role      enum (see role ladder below)
  unique (group_id, user_id)
```

Org-level membership remains the "belongs to this tenant at all" record;
group memberships layer roles onto subtrees.

New/changed `Organizations` public functions (illustrative):
`create_group/2`, `move_group/2` (re-computes subtree paths in a `Multi`),
`add_group_member/3`, `groups_for_user/1`, `ancestor_group_ids/1`,
`descendant_resource_scope/1`.

### 2. Polymorphic resource ownership

`history_sessions` (and `documents`, same treatment) gain:

```
owner_type   enum [:user, :group]
owner_id     binary_id            (a users.id OR a groups.id)
org_id       binary_id null       (denormalized tenant; null for pre-org personal docs)
owner_path   ltree   null         (denormalized group path when owner_type=:group; for fast subtree scoping)
```

- Personal document → `owner_type: :user, owner_id: <user>`.
- Institutional document → `owner_type: :group, owner_id: <group>`, `owner_path`
  copied from the group for subtree queries.
- `org_id` denormalized so "everything in this tenant" never needs a join through
  ownership; it is the primary tenant-isolation filter.
- The schema keeps a changeset per the repo law; `owner_type`/`owner_id` are
  validated together (a `:group` owner must reference a real group in the same
  `org_id`).

### 3. Resource grants — the sharing primitive

```
resource_grants
  id             binary_id pk
  resource_type  enum [:session]      (extensible; only :session in Spec 1)
  resource_id    binary_id
  subject_type   enum [:user, :group] (grant to a person or a whole group)
  subject_id     binary_id
  role           enum (role ladder)
  granted_by     binary_id
  timestamps
  unique (resource_type, resource_id, subject_type, subject_id)
```

A grant attaches a role to a (user|group) on a specific resource — the basis for
"invite someone to comment on this document" (Spec 2 builds the invite flow on
top; the table lands now so the policy engine can already read it).

### 4. The `Authz` context — the policy choke point

A **new context** `PerfectPaper.Authz`. Its single public entry point:

```elixir
@type subject :: Accounts.Scope.t()
@type action  :: :read | :comment | :edit | :delete | :share | :manage_members | ...
@type resource :: History.Session.t() | Organizations.Group.t() | ...
@type env :: map()        # request-time attributes: time, ip, source; empty in Spec 1
@type decision :: :ok | {:error, :unauthorized} | {:error, :not_found}

@spec permit?(subject, action, resource, env) :: decision
@spec permit?(subject, action, resource) :: decision   # env defaults to %{}
```

**Subject = the existing `Accounts.Scope`**, enriched with resolved roles/group
memberships (the repo already threads a Scope; it is the natural attribute
carrier). `Authz` exposes `Authz.load_subject(user)` to build an enriched scope.

**Rules are pure Elixir pattern-matching** over the seeded RBAC set — no rules
engine. The ABAC *shape* (4-arity, attribute-carrying subject/resource/env) is the
future-proofing: new attribute rules slot in as new clauses, call sites never
change.

The **list path** does NOT loop `permit?/4` per row. `Authz` exposes a
composable query scope that narrows an Ecto query to what a subject may see:

```elixir
@spec scope_query(Ecto.Queryable.t(), Accounts.Scope.t(), action()) :: Ecto.Query.t()
def scope_query(query, %Scope{user: %{id: uid}} = scope, :read) do
  paths = authorized_group_paths(scope)   # ltree paths the subject holds a role at

  from s in query,
    where:
      (s.owner_type == :user and s.owner_id == ^uid) or
        (s.owner_type == :group and fragment("? <@ ANY(?)", s.owner_path, ^paths))
end
```

so `History` list becomes `Session |> Authz.scope_query(scope, :read) |> Repo.all()`.
Single-resource actions use `permit?/4`. Decision sketch:

```elixir
# Direct user owner
def permit?(%Scope{user: %{id: uid}}, _action,
            %Session{owner_type: :user, owner_id: uid}, _env), do: :ok

# Group-owned: a role at the owning group OR any ANCESTOR satisfies it,
# provided the role clears the action's required level. Inheritance is UP the tree.
def permit?(%Scope{} = s, action,
            %Session{owner_type: :group, owner_path: path} = r, _env) do
  if role_at_or_above(s, path) |> clears?(required_role(action, r)),
    do: :ok, else: {:error, :unauthorized}
end

# Resource grant (covers external guests in Spec 2 — a guest is just a subject
# with one scoped grant and no org membership)
def permit?(%Scope{} = s, action, %Session{} = r, _env) do
  if granted_role(s, r) |> clears?(required_role(action, r)),
    do: :ok, else: {:error, :unauthorized}
end

# Default deny
def permit?(_subject, _action, _resource, _env), do: {:error, :unauthorized}
```

- `role_at_or_above/2` is an **`ltree` ancestor query** (`group.path @> resource.owner_path`)
  joined to the subject's group memberships — resolving inheritance up the tree in
  one indexed query, not N parent walks.
- **Role ladder** (totally ordered, fixed in Spec 1):
  `owner > admin > editor > commenter > viewer`. `required_role(action, resource)`
  maps an action to the minimum role; `clears?/2` compares ladder positions.
- **Decision log** — `authz_decisions` row
  (`subject_id, action, resource_type, resource_id, decision, reason, inserted_at`).
  Enterprises want "why was this allowed/denied"; it doubles as the audit trail
  SCIM/SSO deals ask for. **Spec 1 logs mutating actions only**
  (`:edit`, `:share`, `:delete`, `:manage_members`) and **skips `:read`** — a
  synchronous INSERT on every read would add per-request latency and bloat for
  the least audit-critical events. At mutation volume a synchronous insert is
  fine and trivially testable. Read-logging and a buffered writer are a later
  optimization; a bare un-awaited `Task.start` is **deliberately avoided** — async
  side-effects are out of scope this pass (CLAUDE.md) and aren't deterministically
  testable. Logging is best-effort and never alters the decision.

### 5. Call-site refactor (mandatory — a choke point nobody calls is theater)

`History` stops embedding `s.user_id == ^user_id`. Instead:

1. Queries scope by **tenant + ownership/grant** the user can see (a query builder
   in `Authz` returns the `where` fragment / a composable scope; the *list* path
   stays a query, not a per-row `permit?`).
2. Mutating paths (`dismiss_comment`, `address_comment`, etc.) call
   `Authz.permit?(scope, action, session, env)` and return the FallbackController's
   uniform `unauthorized` on `{:error, :unauthorized}`.

This is done while `History` is the only consumer — cheapest it will ever be.

## Migration & rollout — expand/contract (no big-bang)

Existing single-owner rows must survive. Sequence (each a separate, reversible
step):

1. **Expand** — migration adds `owner_type`, `owner_id`, `org_id`, `owner_path` to
   `history_sessions` (+ `documents`); creates `groups` (with **GiST index on
   `path`**), `group_memberships`, `resource_grants`, `authz_decisions`. Old
   `user_id` column stays.
2. **Backfill** — a **`mix` task / data step** (⚠️ **not Oban** — async/background
   jobs are out of scope this pass per CLAUDE.md) copies each `user_id` →
   `owner_id` with `owner_type = :user`. Idempotent and re-runnable.
3. **Switch** — application reads/writes go through the polymorphic columns and
   `Authz`. `user_id` is now redundant but still populated (dual-write briefly if
   needed for safety).
4. **Contract** — a later migration drops `user_id` once nothing reads it.

Steps 1–3 are Spec 1. Step 4 can land at the end of Spec 1 or early Spec 2.

## Error handling

- `permit?` distinguishes two denial shapes so HTTP semantics are both
  existence-hiding *and* honest:
  - **`{:error, :not_found}` → 404** when the subject has no line of sight to the
    resource at all (not owner, not a member of any ancestor group, no grant).
    Returning 404 — identical to a truly-missing id — hides existence and
    preserves the IDOR fix's posture. The list `scope_query` already filters
    these out, so a single-resource lookup that misses simply 404s.
  - **`{:error, :unauthorized}` → 403** when the subject *can* see the resource
    (it's shared with them / they're a `viewer`) but the action exceeds their
    role (e.g. a commenter attempting `:edit`). Existence isn't secret here, so a
    404 would be a confusing lie; 403 is the honest, useful answer.
  `FallbackController` maps each to its status.
- Group `move`/path recomputation runs in `Ecto.Multi`; partial failure rolls
  back the whole subtree update.
- Polymorphic owner integrity (group owner must exist in same org) enforced in the
  changeset; DB-level FK can't span the polymorphic column, so the changeset is
  the guard (repo law: changeset on every write).

## Testing strategy

ExUnit against real Postgres (`DataCase`/`ConnCase`).

- **`Authz` policy table tests** — a matrix of (subject role × action × ownership
  kind × grant) asserting allow/deny, including **inheritance up the tree**
  (ancestor role grants access; sibling/descendant role does not) and **default
  deny**.
- **`ltree` queries** — ancestor/descendant scoping returns the right subtree;
  GiST index present.
- **Migration/backfill** — existing `user_id` rows end up `owner_type: :user`,
  authz behavior is unchanged for pre-existing personal docs (regression guard on
  the IDOR fix).
- **History controller** — routed through `Authz`: a non-owner with no line of
  sight gets **404** (existence hidden); a subject who can see the resource but
  lacks the role for the action gets **403**; never 200.

Per repo guidance: write/run only the tests covering this work while developing;
full `mix precommit` reserved for the pre-merge check.

## Open questions / deferred to later specs

- **Org-without-group personal users** — pre-enterprise signups have no org. They
  stay `owner_type: :user, org_id: null`; an org/group can later *claim* a
  personal doc (an ownership transfer function — Spec 2+).
- **Grant to a group subtree vs. exact group** — Spec 1 grants target an exact
  group; subtree-cascading grants can be added as a grant attribute later.
- **Custom org-defined roles** — the ABAC interface allows it; Spec 1 ships the
  fixed ladder only. Revisit if a deal demands custom roles.
- **Decision-log volume/retention** — sampling/TTL policy is a Spec 3/4 concern.

## Definition of done (Spec 1)

- Nested groups + `ltree` path + GiST index, with `Organizations` API for
  create/move/membership.
- Polymorphic ownership on sessions/documents; existing rows backfilled to
  `:user`.
- `resource_grants` table in place and readable by the policy engine.
- `Authz.permit?/3,4` choke point with the seeded role ladder, ancestor-inheritance
  resolution, decision log, and default-deny.
- `History` fully routed through `Authz` (no inline `user_id ==`); reference
  controller returns 404 for no-line-of-sight and 403 for insufficient-role.
- Tests green for all of the above.
