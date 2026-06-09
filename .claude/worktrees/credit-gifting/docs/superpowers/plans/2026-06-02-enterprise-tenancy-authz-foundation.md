# Enterprise Tenancy & Authorization Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move PerfectPaper off its single-owner (`session.user_id ==`) model onto an enterprise-ready foundation: nested groups (Postgres ltree), polymorphic resource ownership, resource grants, and a single `Authz` policy choke point that the `History` context routes through.

**Architecture:** A new `Authz` context owns the only `permit?/4` decision function (ABAC-shaped signature, RBAC rules via Elixir pattern-matching) plus a composable `scope_query/3` for list paths. `Organizations` grows a group tree. Resources gain `owner_type`/`owner_id`/`org_id`/`owner_path`. Existing `user_id` rows are backfilled to `owner_type: :user` and **not** dropped this pass (expand/contract). `History` stops embedding ownership checks and asks `Authz`.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto + PostgreSQL (`binary_id` PKs, `ltree` extension), ExUnit with `DataCase`/`ConnCase`.

**Spec:** `docs/superpowers/specs/2026-06-02-enterprise-tenancy-authz-foundation-design.md`

---

## Locked conventions (read before any task)

These names/signatures are referenced across tasks. Keep them exact.

- **Role ladder** (ascending): `:viewer < :commenter < :editor < :admin < :owner`.
- **Action → required role:** `:read → :viewer`, `:comment → :commenter`, `:edit → :editor`, `:delete → :admin`, `:share → :admin`, `:manage_members → :admin`.
- **Mutating actions** (logged to `authz_decisions`): `:edit`, `:delete`, `:share`, `:manage_members`. (`:read`, `:comment` are not logged in Spec 1.)
- **ltree path representation:** a group's `path` is a dotted string of ancestor UUIDs **with hyphens stripped** (ltree labels allow only `[A-Za-z0-9_]`). Helper: `label(id) = String.replace(id, "-", "")`. Top-level group path = `label(id)`; child path = `parent.path <> "." <> label(id)`.
- **ltree storage:** `path` is a **`:text` column** with an **expression GiST index** `USING GIST ((path::ltree))`. All subtree queries cast: `fragment("?::ltree <@ ANY(?::ltree[])", g.path, ^paths)`. (Avoids Postgrex ltree-OID decode issues — text decodes natively.)
- **Subject:** the enriched `PerfectPaper.Accounts.Scope` struct, gaining a `group_paths` field (list of ltree path strings the user holds a role at). Built by `Authz.load_subject/1`.
- **`permit?` return:** `:ok | {:error, :unauthorized} | {:error, :not_found}`. `:not_found` = no line of sight (hide existence → 404); `:unauthorized` = visible but role insufficient (→ 403).
- **Inheritance direction:** UP the tree — a role at an ancestor group covers descendant-owned resources. Resource owned at path `R` is covered by membership at path `M` iff `R <@ M` (`R` is a descendant of, or equal to, `M`).

### Scope note (no silent caps)

- This plan fully wires **`history_sessions`** + the **`History`** context/controller through `Authz`. It **adds ownership columns to `documents`** (forward-compat, same migration pattern) but does **not** refactor the `Documents` context call sites — `Documents` isn't the reference controller and gets wired when it's next touched (Spec 2). Stated deliberately.
- **List-path visibility via grants** is deferred: `scope_query/3` covers user-owned + group-owned resources. Grant-based visibility for *lists* lands with the sharing/invite flow (Spec 2), when grants actually get created. Single-resource `permit?/4` **does** honor grants now.

---

## File structure

**Create:**
- `lib/perfect_paper/authz.ex` — the `Authz` context: `permit?/3,4`, `scope_query/3`, `load_subject/1`, decision logging.
- `lib/perfect_paper/authz/role.ex` — the role ladder (`clears?/2`, `required_for/1`).
- `lib/perfect_paper/authz/decision.ex` — `AuthzDecision` schema + changeset.
- `lib/perfect_paper/organizations/group.ex` — `Group` schema + changeset.
- `lib/perfect_paper/organizations/group_membership.ex` — `GroupMembership` schema + changeset.
- `lib/perfect_paper/authz/resource_grant.ex` — `ResourceGrant` schema + changeset.
- `priv/repo/migrations/20260602100000_create_groups.exs`
- `priv/repo/migrations/20260602100100_create_group_memberships.exs`
- `priv/repo/migrations/20260602100200_add_polymorphic_ownership.exs`
- `priv/repo/migrations/20260602100300_create_resource_grants.exs`
- `priv/repo/migrations/20260602100400_create_authz_decisions.exs`
- `test/perfect_paper/authz_test.exs`
- `test/support/fixtures/authz_fixtures.ex`

**Modify:**
- `lib/perfect_paper/accounts/scope.ex` — add `group_paths` field.
- `lib/perfect_paper/organizations.ex` — `create_group/2`, `add_group_member/3`, `authorized_group_paths/1`.
- `lib/perfect_paper/history/session.ex` — ownership fields + changeset.
- `lib/perfect_paper/history.ex` — route reads/mutations through `Authz`.
- `lib/perfect_paper_web/controllers/api/history_controller.ex` — build scope, map results.
- `lib/perfect_paper_web/controllers/api/fallback_controller.ex` — `:unauthorized → 403`.
- `test/support/fixtures/organizations_fixtures.ex` — group + membership fixtures.
- `test/support/fixtures/history_fixtures.ex` — group-owned session fixture.
- `test/perfect_paper/history_test.exs`, `test/perfect_paper_web/controllers/api/history_controller_test.exs` — updated for scope.

---

## Task 1: Role ladder module

Pure logic, no IO — build it first so later tasks can use it.

**Files:**
- Create: `lib/perfect_paper/authz/role.ex`
- Test: `test/perfect_paper/authz/role_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/perfect_paper/authz/role_test.exs`:

```elixir
defmodule PerfectPaper.Authz.RoleTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Authz.Role

  test "clears?/2 is true when held role is at or above required" do
    assert Role.clears?(:owner, :editor)
    assert Role.clears?(:editor, :editor)
    assert Role.clears?(:admin, :read |> Role.required_for())
  end

  test "clears?/2 is false when held role is below required" do
    refute Role.clears?(:viewer, :editor)
    refute Role.clears?(:commenter, :edit |> Role.required_for())
  end

  test "clears?/2 is false when held role is nil (no role at all)" do
    refute Role.clears?(nil, :viewer)
  end

  test "required_for/1 maps actions to the minimum role" do
    assert Role.required_for(:read) == :viewer
    assert Role.required_for(:comment) == :commenter
    assert Role.required_for(:edit) == :editor
    assert Role.required_for(:delete) == :admin
    assert Role.required_for(:share) == :admin
    assert Role.required_for(:manage_members) == :admin
  end

  test "mutating?/1 flags only audit-relevant actions" do
    assert Role.mutating?(:edit)
    assert Role.mutating?(:delete)
    refute Role.mutating?(:read)
    refute Role.mutating?(:comment)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/perfect_paper/authz/role_test.exs`
Expected: FAIL — `module PerfectPaper.Authz.Role is not available`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/perfect_paper/authz/role.ex`:

```elixir
defmodule PerfectPaper.Authz.Role do
  @moduledoc """
  The fixed role ladder for Spec 1 authorization and the action→role mapping.

  Roles are totally ordered: `:viewer < :commenter < :editor < :admin < :owner`.
  A held role "clears" an action when it sits at or above the action's minimum.
  """

  @ladder [:viewer, :commenter, :editor, :admin, :owner]

  @required %{
    read: :viewer,
    comment: :commenter,
    edit: :editor,
    delete: :admin,
    share: :admin,
    manage_members: :admin
  }

  @mutating [:edit, :delete, :share, :manage_members]

  @type t :: :viewer | :commenter | :editor | :admin | :owner
  @type action :: :read | :comment | :edit | :delete | :share | :manage_members

  @doc "The minimum role required to perform `action`."
  @spec required_for(action()) :: t()
  def required_for(action), do: Map.fetch!(@required, action)

  @doc "Whether `held` role sits at or above `required`. `nil` held never clears."
  @spec clears?(t() | nil, t()) :: boolean()
  def clears?(nil, _required), do: false

  def clears?(held, required) do
    rank(held) >= rank(required)
  end

  @doc "Whether `action` is audit-logged (mutating) in Spec 1."
  @spec mutating?(action()) :: boolean()
  def mutating?(action), do: action in @mutating

  defp rank(role), do: Enum.find_index(@ladder, &(&1 == role))
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/perfect_paper/authz/role_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/authz/role.ex test/perfect_paper/authz/role_test.exs
git commit -m "feat(authz): role ladder with clears?/required_for/mutating?"
```

---

## Task 2: Groups table migration + Group schema

**Files:**
- Create: `priv/repo/migrations/20260602100000_create_groups.exs`
- Create: `lib/perfect_paper/organizations/group.ex`
- Test: `test/perfect_paper/organizations/group_test.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260602100000_create_groups.exs`:

```elixir
defmodule PerfectPaper.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS ltree", "DROP EXTENSION IF EXISTS ltree"

    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :parent_id, references(:groups, type: :binary_id, on_delete: :delete_all)
      add :name, :string, null: false
      add :kind, :string, null: false, default: "group"
      # ltree materialized path, stored as text; queried via path::ltree (see plan).
      add :path, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:groups, [:organization_id])
    create index(:groups, [:parent_id])

    # Expression GiST index so `path::ltree <@ ...` subtree queries stay fast.
    execute(
      "CREATE INDEX groups_path_gist_idx ON groups USING GIST ((path::ltree))",
      "DROP INDEX groups_path_gist_idx"
    )
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/perfect_paper/organizations/group_test.exs`:

```elixir
defmodule PerfectPaper.Organizations.GroupTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Organizations.Group

  test "create_changeset requires organization_id, name, path" do
    changeset = Group.create_changeset(%Group{}, %{})
    refute changeset.valid?
    assert %{organization_id: _, name: _, path: _} = errors_on(changeset)
  end

  test "create_changeset accepts a valid group" do
    changeset =
      Group.create_changeset(%Group{}, %{
        organization_id: Ecto.UUID.generate(),
        name: "English Dept",
        kind: :department,
        path: "abc.def"
      })

    assert changeset.valid?
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/perfect_paper/organizations/group_test.exs`
Expected: FAIL — `PerfectPaper.Organizations.Group is not available`.

- [ ] **Step 4: Write the schema**

Create `lib/perfect_paper/organizations/group.ex`:

```elixir
defmodule PerfectPaper.Organizations.Group do
  @moduledoc """
  A node in an organization's group tree (college → department → lab → team).

  `path` is an ltree materialized path of ancestor group ids (hyphens stripped),
  stored as text and queried via `path::ltree`. The context maintains it; it is
  never cast from user input.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Organizations.Organization

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "groups" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:college, :department, :team, :lab, :group], default: :group
    field :path, :string
    field :parent_id, :binary_id

    belongs_to :organization, Organization

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a group. `path` is computed by the context."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(group, attrs) do
    group
    |> cast(attrs, [:id, :name, :kind, :path, :parent_id, :organization_id])
    |> validate_required([:organization_id, :name, :path])
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/perfect_paper/organizations/group_test.exs`
Expected: PASS (2 tests). (Migration runs automatically via the `test` alias.)

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/20260602100000_create_groups.exs lib/perfect_paper/organizations/group.ex test/perfect_paper/organizations/group_test.exs
git commit -m "feat(organizations): groups table (ltree path) + Group schema"
```

---

## Task 3: Group memberships migration + GroupMembership schema

**Files:**
- Create: `priv/repo/migrations/20260602100100_create_group_memberships.exs`
- Create: `lib/perfect_paper/organizations/group_membership.ex`
- Test: `test/perfect_paper/organizations/group_membership_test.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260602100100_create_group_memberships.exs`:

```elixir
defmodule PerfectPaper.Repo.Migrations.CreateGroupMemberships do
  use Ecto.Migration

  def change do
    create table(:group_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "viewer"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_memberships, [:group_id, :user_id])
    create index(:group_memberships, [:user_id])
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/perfect_paper/organizations/group_membership_test.exs`:

```elixir
defmodule PerfectPaper.Organizations.GroupMembershipTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Organizations.GroupMembership

  test "create_changeset requires group_id and user_id" do
    changeset = GroupMembership.create_changeset(%GroupMembership{}, %{})
    refute changeset.valid?
    assert %{group_id: _, user_id: _} = errors_on(changeset)
  end

  test "create_changeset accepts a valid membership with a role" do
    changeset =
      GroupMembership.create_changeset(%GroupMembership{}, %{
        group_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        role: :editor
      })

    assert changeset.valid?
    assert get_change(changeset, :role) == :editor
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/perfect_paper/organizations/group_membership_test.exs`
Expected: FAIL — module not available.

- [ ] **Step 4: Write the schema**

Create `lib/perfect_paper/organizations/group_membership.ex`:

```elixir
defmodule PerfectPaper.Organizations.GroupMembership do
  @moduledoc """
  A user's role at a node in an organization's group tree. Roles inherit *down*
  the tree: a role here applies to resources owned by this group or any descendant.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Organizations.Group

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_memberships" do
    field :role, Ecto.Enum,
      values: [:viewer, :commenter, :editor, :admin, :owner],
      default: :viewer

    field :user_id, :binary_id

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for adding a user to a group with a role."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :group_id, :user_id])
    |> validate_required([:group_id, :user_id])
    |> unique_constraint([:group_id, :user_id])
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/perfect_paper/organizations/group_membership_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/20260602100100_create_group_memberships.exs lib/perfect_paper/organizations/group_membership.ex test/perfect_paper/organizations/group_membership_test.exs
git commit -m "feat(organizations): group_memberships table + schema (role ladder)"
```

---

## Task 4: Organizations context — group tree API + fixtures

Adds `create_group/2` (computes ltree path), `add_group_member/3`, and `authorized_group_paths/1`.

**Files:**
- Modify: `lib/perfect_paper/organizations.ex`
- Modify: `test/support/fixtures/organizations_fixtures.ex`
- Test: `test/perfect_paper/organizations_test.exs` (create if absent; otherwise append)

- [ ] **Step 1: Add fixtures**

In `test/support/fixtures/organizations_fixtures.ex`, add inside the module:

```elixir
  @doc "Creates a group in the org. Pass `parent: %Group{}` for a child node."
  def group_fixture(org, attrs \\ %{}) do
    attrs = Map.new(attrs)
    parent = attrs[:parent]

    {:ok, group} =
      PerfectPaper.Organizations.create_group(org, %{
        name: attrs[:name] || "Group #{System.unique_integer([:positive])}",
        kind: attrs[:kind] || :group,
        parent_id: parent && parent.id
      })

    group
  end

  @doc "Adds a user to a group with the given role (default :viewer)."
  def group_membership_fixture(group, user, role \\ :viewer) do
    {:ok, m} = PerfectPaper.Organizations.add_group_member(group, user, role)
    m
  end
```

- [ ] **Step 2: Write the failing test**

Create/append `test/perfect_paper/organizations_test.exs`:

```elixir
defmodule PerfectPaper.OrganizationsTest do
  use PerfectPaper.DataCase, async: true

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  alias PerfectPaper.Organizations

  describe "create_group/2" do
    test "top-level group path is the hyphen-stripped id" do
      owner = user_fixture()
      org = organization_fixture(owner)
      {:ok, group} = Organizations.create_group(org, %{name: "College of Arts"})

      assert group.path == String.replace(group.id, "-", "")
      assert group.parent_id == nil
    end

    test "child group path appends its label under the parent path" do
      owner = user_fixture()
      org = organization_fixture(owner)
      {:ok, parent} = Organizations.create_group(org, %{name: "College"})
      {:ok, child} = Organizations.create_group(org, %{name: "Dept", parent_id: parent.id})

      assert child.path == parent.path <> "." <> String.replace(child.id, "-", "")
    end
  end

  describe "authorized_group_paths/1" do
    test "returns ltree paths of every group the user holds a role at" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      {:ok, college} = Organizations.create_group(org, %{name: "College"})
      {:ok, _dept} = Organizations.create_group(org, %{name: "Dept", parent_id: college.id})

      group_membership_fixture(college, member, :admin)

      assert Organizations.authorized_group_paths(member.id) == [college.path]
    end

    test "returns [] for a user with no group memberships" do
      assert Organizations.authorized_group_paths(Ecto.UUID.generate()) == []
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/perfect_paper/organizations_test.exs`
Expected: FAIL — `function PerfectPaper.Organizations.create_group/2 is undefined`.

- [ ] **Step 4: Implement the context functions**

In `lib/perfect_paper/organizations.ex`, update the alias line and add functions.

Change the alias:

```elixir
  alias PerfectPaper.Organizations.{Organization, Membership, Group, GroupMembership, Notifier}
```

Add to the module body (e.g. under a new `# ── Group tree ──` section):

```elixir
  @doc """
  Creates a group in `org`. Pass `:parent_id` to nest it; omit for a top-level
  group. Computes the ltree `path` (ancestor ids, hyphens stripped) here so the
  schema changeset stays pure.
  """
  @spec create_group(Organization.t(), map()) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t() | :parent_not_found}
  def create_group(%Organization{} = org, attrs) do
    attrs = Map.new(attrs)
    id = Ecto.UUID.generate()

    with {:ok, parent_path} <- parent_path(org.id, attrs[:parent_id]) do
      path = join_path(parent_path, id)

      %Group{}
      |> Group.create_changeset(%{
        id: id,
        organization_id: org.id,
        parent_id: attrs[:parent_id],
        name: attrs[:name],
        kind: attrs[:kind] || :group,
        path: path
      })
      |> Repo.insert()
    end
  end

  @doc "Adds a user to a group with a role (default :viewer)."
  @spec add_group_member(Group.t(), struct(), atom()) ::
          {:ok, GroupMembership.t()} | {:error, Ecto.Changeset.t()}
  def add_group_member(%Group{} = group, user, role \\ :viewer) do
    %GroupMembership{}
    |> GroupMembership.create_changeset(%{group_id: group.id, user_id: user.id, role: role})
    |> Repo.insert()
  end

  @doc "ltree paths of every group `user_id` holds a role at (for authz scoping)."
  @spec authorized_group_paths(Ecto.UUID.t()) :: [String.t()]
  def authorized_group_paths(user_id) do
    Repo.all(
      from m in GroupMembership,
        join: g in Group,
        on: g.id == m.group_id,
        where: m.user_id == ^user_id,
        select: g.path
    )
  end

  # path of the parent group, validated to belong to the same org; "" when top-level.
  defp parent_path(_org_id, nil), do: {:ok, ""}

  defp parent_path(org_id, parent_id) do
    case Repo.one(from g in Group, where: g.id == ^parent_id and g.organization_id == ^org_id) do
      nil -> {:error, :parent_not_found}
      %Group{path: path} -> {:ok, path}
    end
  end

  defp join_path("", id), do: label(id)
  defp join_path(parent_path, id), do: parent_path <> "." <> label(id)

  defp label(id), do: String.replace(id, "-", "")
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/perfect_paper/organizations_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/organizations.ex test/support/fixtures/organizations_fixtures.ex test/perfect_paper/organizations_test.exs
git commit -m "feat(organizations): create_group/add_group_member/authorized_group_paths"
```

---

## Task 5: Polymorphic ownership migration + backfill

Adds ownership columns to `history_sessions` (and `documents`, forward-compat), backfills existing rows to `owner_type: :user`, then enforces NOT NULL on sessions. `user_id` stays (expand/contract — dropped in a later pass).

**Files:**
- Create: `priv/repo/migrations/20260602100200_add_polymorphic_ownership.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260602100200_add_polymorphic_ownership.exs`:

```elixir
defmodule PerfectPaper.Repo.Migrations.AddPolymorphicOwnership do
  use Ecto.Migration

  def up do
    alter table(:history_sessions) do
      add :owner_type, :string
      add :owner_id, :binary_id
      add :organization_id, :binary_id
      add :owner_path, :text
    end

    alter table(:documents) do
      add :owner_type, :string
      add :owner_id, :binary_id
      add :organization_id, :binary_id
      add :owner_path, :text
    end

    # Backfill existing single-owner rows. Idempotent (guarded on NULL).
    execute """
    UPDATE history_sessions
    SET owner_type = 'user', owner_id = user_id
    WHERE owner_id IS NULL
    """

    execute """
    UPDATE documents
    SET owner_type = 'user', owner_id = user_id
    WHERE owner_id IS NULL
    """

    # Sessions are the fully-wired resource — enforce presence now.
    alter table(:history_sessions) do
      modify :owner_type, :string, null: false
      modify :owner_id, :binary_id, null: false
    end

    create index(:history_sessions, [:owner_type, :owner_id])
    create index(:history_sessions, [:organization_id])

    execute(
      "CREATE INDEX history_sessions_owner_path_gist_idx ON history_sessions USING GIST ((owner_path::ltree))",
      ""
    )
  end

  def down do
    execute "DROP INDEX IF EXISTS history_sessions_owner_path_gist_idx"
    drop index(:history_sessions, [:organization_id])
    drop index(:history_sessions, [:owner_type, :owner_id])

    alter table(:documents) do
      remove :owner_type
      remove :owner_id
      remove :organization_id
      remove :owner_path
    end

    alter table(:history_sessions) do
      remove :owner_type
      remove :owner_id
      remove :organization_id
      remove :owner_path
    end
  end
end
```

- [ ] **Step 2: Run the migration to verify it applies**

Run: `mix ecto.migrate`
Expected: migration `AddPolymorphicOwnership` runs without error (creates columns + GiST index).

- [ ] **Step 3: Verify rollback works**

Run: `mix ecto.rollback` then `mix ecto.migrate`
Expected: down + up both succeed (proves the expression index and column changes are reversible). Re-migrate to leave the DB current.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/20260602100200_add_polymorphic_ownership.exs
git commit -m "feat(history): polymorphic ownership columns + backfill (expand step)"
```

---

## Task 6: Session schema + History.begin_session set owner

`Session` gains the ownership fields; its `create_changeset` casts them; `History.begin_session` derives `owner_type: :user`/`owner_id` from `user_id` so existing callers keep working.

**Files:**
- Modify: `lib/perfect_paper/history/session.ex`
- Modify: `lib/perfect_paper/history.ex` (begin_session only, this task)
- Modify: `test/support/fixtures/history_fixtures.ex`
- Test: `test/perfect_paper/history_test.exs` (append one test)

- [ ] **Step 1: Write the failing test**

Append to `test/perfect_paper/history_test.exs` (inside the test module):

```elixir
  describe "begin_session/1 ownership" do
    test "defaults a user-owned session from user_id" do
      user = PerfectPaper.AccountsFixtures.user_fixture()
      {:ok, session} = PerfectPaper.History.begin_session(%{user_id: user.id, title: "Doc"})

      assert session.owner_type == :user
      assert session.owner_id == user.id
      assert session.user_id == user.id
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: FAIL — `session.owner_type` is `nil` (field/derivation missing).

- [ ] **Step 3: Update the Session schema**

In `lib/perfect_paper/history/session.ex`, add fields to the schema (after `field :user_id, :binary_id`):

```elixir
    field :owner_type, Ecto.Enum, values: [:user, :group]
    field :owner_id, :binary_id
    field :organization_id, :binary_id
    field :owner_path, :string
```

Replace `create_changeset/2` with:

```elixir
  @doc "Begins a session for a writer's uploaded manuscript."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :title,
      :user_id,
      :processing_status,
      :owner_type,
      :owner_id,
      :organization_id,
      :owner_path
    ])
    |> validate_required([:owner_type, :owner_id])
  end
```

- [ ] **Step 4: Derive ownership in begin_session**

In `lib/perfect_paper/history.ex`, replace `begin_session/1`:

```elixir
  @doc "Begins a proofreading session for an uploaded manuscript."
  @spec begin_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def begin_session(attrs) do
    attrs = with_user_owner(Map.new(attrs))
    %Session{} |> Session.create_changeset(attrs) |> Repo.insert()
  end

  # A session created from a bare user_id is user-owned. Group-owned sessions
  # pass owner_type/owner_id (+ owner_path/organization_id) explicitly.
  defp with_user_owner(%{user_id: user_id} = attrs) when not is_nil(user_id) do
    attrs
    |> Map.put_new(:owner_type, :user)
    |> Map.put_new(:owner_id, user_id)
  end

  defp with_user_owner(attrs), do: attrs
```

- [ ] **Step 5: Update the session fixture to support group ownership**

In `test/support/fixtures/history_fixtures.ex`, replace `session_fixture/1` with:

```elixir
  @doc """
  Creates a session. Defaults to a fresh user as owner. Pass `group: %Group{}`
  (and the path is taken from it) to create a group-owned session.
  """
  def session_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    case attrs[:group] do
      nil ->
        user = attrs[:user] || user_fixture()
        {:ok, s} = History.begin_session(%{user_id: user.id, title: attrs[:title] || "Doc"})
        s

      group ->
        {:ok, s} =
          History.begin_session(%{
            owner_type: :group,
            owner_id: group.id,
            organization_id: group.organization_id,
            owner_path: group.path,
            title: attrs[:title] || "Doc"
          })

        s
    end
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: PASS (existing tests + the new ownership test). If a pre-existing test inserted a session without `user_id`, it now needs `owner_type/owner_id` — fix any such test inline.

- [ ] **Step 7: Commit**

```bash
git add lib/perfect_paper/history/session.ex lib/perfect_paper/history.ex test/support/fixtures/history_fixtures.ex test/perfect_paper/history_test.exs
git commit -m "feat(history): Session ownership fields; begin_session derives user owner"
```

---

## Task 7: resource_grants table + ResourceGrant schema

The sharing primitive. Table + schema land now so `Authz` can read grants; the invite flow that *creates* grants is Spec 2.

**Files:**
- Create: `priv/repo/migrations/20260602100300_create_resource_grants.exs`
- Create: `lib/perfect_paper/authz/resource_grant.ex`
- Test: `test/perfect_paper/authz/resource_grant_test.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260602100300_create_resource_grants.exs`:

```elixir
defmodule PerfectPaper.Repo.Migrations.CreateResourceGrants do
  use Ecto.Migration

  def change do
    create table(:resource_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false
      add :subject_type, :string, null: false
      add :subject_id, :binary_id, null: false
      add :role, :string, null: false
      add :granted_by, :binary_id

      timestamps(type: :utc_datetime)
    end

    create unique_index(:resource_grants, [:resource_type, :resource_id, :subject_type, :subject_id],
             name: :resource_grants_unique_index
           )

    create index(:resource_grants, [:subject_type, :subject_id])
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/perfect_paper/authz/resource_grant_test.exs`:

```elixir
defmodule PerfectPaper.Authz.ResourceGrantTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Authz.ResourceGrant

  test "create_changeset requires resource, subject, and role" do
    changeset = ResourceGrant.create_changeset(%ResourceGrant{}, %{})
    refute changeset.valid?
    errors = errors_on(changeset)
    assert Map.has_key?(errors, :resource_type)
    assert Map.has_key?(errors, :resource_id)
    assert Map.has_key?(errors, :subject_type)
    assert Map.has_key?(errors, :subject_id)
    assert Map.has_key?(errors, :role)
  end

  test "create_changeset accepts a valid grant" do
    changeset =
      ResourceGrant.create_changeset(%ResourceGrant{}, %{
        resource_type: :session,
        resource_id: Ecto.UUID.generate(),
        subject_type: :user,
        subject_id: Ecto.UUID.generate(),
        role: :commenter,
        granted_by: Ecto.UUID.generate()
      })

    assert changeset.valid?
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/perfect_paper/authz/resource_grant_test.exs`
Expected: FAIL — module not available.

- [ ] **Step 4: Write the schema**

Create `lib/perfect_paper/authz/resource_grant.ex`:

```elixir
defmodule PerfectPaper.Authz.ResourceGrant do
  @moduledoc """
  A grant attaching a role to a subject (a user or a group) on a specific
  resource — the sharing primitive. Read by the policy engine; created by the
  invite/sharing flow (Spec 2).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "resource_grants" do
    field :resource_type, Ecto.Enum, values: [:session]
    field :resource_id, :binary_id
    field :subject_type, Ecto.Enum, values: [:user, :group]
    field :subject_id, :binary_id
    field :role, Ecto.Enum, values: [:viewer, :commenter, :editor, :admin, :owner]
    field :granted_by, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a resource grant."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(grant, attrs) do
    grant
    |> cast(attrs, [:resource_type, :resource_id, :subject_type, :subject_id, :role, :granted_by])
    |> validate_required([:resource_type, :resource_id, :subject_type, :subject_id, :role])
    |> unique_constraint([:resource_type, :resource_id, :subject_type, :subject_id],
      name: :resource_grants_unique_index
    )
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/perfect_paper/authz/resource_grant_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/20260602100300_create_resource_grants.exs lib/perfect_paper/authz/resource_grant.ex test/perfect_paper/authz/resource_grant_test.exs
git commit -m "feat(authz): resource_grants table + ResourceGrant schema"
```

---

## Task 8: authz_decisions table + AuthzDecision schema

The audit log for mutating decisions.

**Files:**
- Create: `priv/repo/migrations/20260602100400_create_authz_decisions.exs`
- Create: `lib/perfect_paper/authz/decision.ex`
- Test: `test/perfect_paper/authz/decision_test.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260602100400_create_authz_decisions.exs`:

```elixir
defmodule PerfectPaper.Repo.Migrations.CreateAuthzDecisions do
  use Ecto.Migration

  def change do
    create table(:authz_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject_id, :binary_id
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :binary_id
      add :decision, :string, null: false
      add :reason, :string

      # Append-only audit row; created_at only (no updates).
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:authz_decisions, [:subject_id])
    create index(:authz_decisions, [:resource_type, :resource_id])
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/perfect_paper/authz/decision_test.exs`:

```elixir
defmodule PerfectPaper.Authz.DecisionTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Authz.Decision

  test "create_changeset requires action, resource_type, decision" do
    changeset = Decision.create_changeset(%Decision{}, %{})
    refute changeset.valid?
    errors = errors_on(changeset)
    assert Map.has_key?(errors, :action)
    assert Map.has_key?(errors, :resource_type)
    assert Map.has_key?(errors, :decision)
  end

  test "create_changeset accepts a valid decision row" do
    changeset =
      Decision.create_changeset(%Decision{}, %{
        subject_id: Ecto.UUID.generate(),
        action: "edit",
        resource_type: "session",
        resource_id: Ecto.UUID.generate(),
        decision: "ok",
        reason: "owner"
      })

    assert changeset.valid?
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/perfect_paper/authz/decision_test.exs`
Expected: FAIL — module not available.

- [ ] **Step 4: Write the schema**

Create `lib/perfect_paper/authz/decision.ex`:

```elixir
defmodule PerfectPaper.Authz.Decision do
  @moduledoc """
  An append-only audit record of an authorization decision on a mutating action
  (`:edit`, `:delete`, `:share`, `:manage_members`). Reads are not logged in
  Spec 1. Best-effort: writing it never alters the decision it records.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "authz_decisions" do
    field :subject_id, :binary_id
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :decision, :string
    field :reason, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for an audit row."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(decision, attrs) do
    decision
    |> cast(attrs, [:subject_id, :action, :resource_type, :resource_id, :decision, :reason])
    |> validate_required([:action, :resource_type, :decision])
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/perfect_paper/authz/decision_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/20260602100400_create_authz_decisions.exs lib/perfect_paper/authz/decision.ex test/perfect_paper/authz/decision_test.exs
git commit -m "feat(authz): authz_decisions audit table + Decision schema"
```

---

## Task 9: Extend Scope + Authz.load_subject/1

`Accounts.Scope` gains `group_paths`; `Authz.load_subject/1` builds an enriched scope by reading group memberships through the `Organizations` API.

**Files:**
- Modify: `lib/perfect_paper/accounts/scope.ex`
- Create: `lib/perfect_paper/authz.ex` (initial — `load_subject/1` only)
- Create: `test/perfect_paper/authz_test.exs`
- Create: `test/support/fixtures/authz_fixtures.ex`

- [ ] **Step 1: Add the grant fixture**

Create `test/support/fixtures/authz_fixtures.ex`:

```elixir
defmodule PerfectPaper.AuthzFixtures do
  @moduledoc "Test fixtures for the Authz context."

  alias PerfectPaper.Authz.ResourceGrant
  alias PerfectPaper.Repo

  @doc "Grants `role` on a session to a user (subject_type :user)."
  def session_grant_fixture(session, user, role \\ :commenter) do
    {:ok, grant} =
      %ResourceGrant{}
      |> ResourceGrant.create_changeset(%{
        resource_type: :session,
        resource_id: session.id,
        subject_type: :user,
        subject_id: user.id,
        role: role,
        granted_by: user.id
      })
      |> Repo.insert()

    grant
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/perfect_paper/authz_test.exs`:

```elixir
defmodule PerfectPaper.AuthzTest do
  use PerfectPaper.DataCase, async: true

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  alias PerfectPaper.Authz

  describe "load_subject/1" do
    test "carries the user and the ltree paths of its group memberships" do
      user = user_fixture()
      org = organization_fixture(user)
      {:ok, college} = PerfectPaper.Organizations.create_group(org, %{name: "College"})
      group_membership_fixture(college, user, :admin)

      scope = Authz.load_subject(user)

      assert scope.user.id == user.id
      assert scope.group_paths == [college.path]
    end

    test "group_paths is empty for a user with no memberships" do
      scope = Authz.load_subject(user_fixture())
      assert scope.group_paths == []
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/perfect_paper/authz_test.exs`
Expected: FAIL — `PerfectPaper.Authz.load_subject/1 is undefined`.

- [ ] **Step 4: Extend the Scope struct**

In `lib/perfect_paper/accounts/scope.ex`, change the struct and `for_user/1`:

```elixir
  defstruct user: nil, group_paths: []
```

```elixir
  def for_user(%User{} = user) do
    %__MODULE__{user: user, group_paths: []}
  end
```

(Leave `for_user(nil)` returning `nil`.)

- [ ] **Step 5: Create the Authz context with load_subject/1**

Create `lib/perfect_paper/authz.ex`:

```elixir
defmodule PerfectPaper.Authz do
  @moduledoc """
  The single authorization boundary: the only place a "may this subject do this
  to this resource?" question is answered (`permit?/3,4`) and the only place a
  list query is narrowed to what a subject may see (`scope_query/3`).

  Rules are pure Elixir pattern-matching over a fixed role ladder; the 4-arity
  `permit?/4` signature is ABAC-shaped (subject + action + resource + env) so new
  attribute rules can be added as clauses without changing any call site.
  """
  import Ecto.Query

  alias PerfectPaper.{Repo, Organizations}
  alias PerfectPaper.Accounts.Scope

  @doc """
  Builds an enriched `Scope` for `user`, resolving the ltree paths of every group
  the user holds a role at (used by `scope_query/3` and `permit?/4`).
  """
  @spec load_subject(struct()) :: Scope.t()
  def load_subject(user) do
    %Scope{user: user, group_paths: Organizations.authorized_group_paths(user.id)}
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/perfect_paper/authz_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/perfect_paper/accounts/scope.ex lib/perfect_paper/authz.ex test/perfect_paper/authz_test.exs test/support/fixtures/authz_fixtures.ex
git commit -m "feat(authz): enrich Scope with group_paths; Authz.load_subject/1"
```

---

## Task 10: Authz.permit?/4 — the policy choke point

Resolves the subject's effective role on a session (owner → group membership up the tree → grant), compares it to the action's required role, returns `:ok`/`:unauthorized`/`:not_found`, and logs mutating decisions.

**Files:**
- Modify: `lib/perfect_paper/authz.ex`
- Modify: `test/perfect_paper/authz_test.exs`

- [ ] **Step 1: Write the failing tests**

Append to `test/perfect_paper/authz_test.exs` (inside the module):

```elixir
  describe "permit?/4" do
    alias PerfectPaper.History.Session

    import PerfectPaper.HistoryFixtures
    import PerfectPaper.AuthzFixtures

    test "user owner may read and edit their own session" do
      user = user_fixture()
      session = session_fixture(user: user) |> Repo.reload()
      scope = Authz.load_subject(user)

      assert Authz.permit?(scope, :read, session) == :ok
      assert Authz.permit?(scope, :edit, session) == :ok
    end

    test "unrelated user gets :not_found (no line of sight)" do
      session = session_fixture() |> Repo.reload()
      scope = Authz.load_subject(user_fixture())

      assert Authz.permit?(scope, :read, session) == {:error, :not_found}
    end

    test "ancestor-group role covers a descendant-group-owned session" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      {:ok, college} = Organizations.create_group(org, %{name: "College"})
      {:ok, dept} = Organizations.create_group(org, %{name: "Dept", parent_id: college.id})
      group_membership_fixture(college, member, :editor)

      session = session_fixture(group: dept) |> Repo.reload()
      scope = Authz.load_subject(member)

      assert Authz.permit?(scope, :read, session) == :ok
      assert Authz.permit?(scope, :edit, session) == :ok
      assert Authz.permit?(scope, :delete, session) == {:error, :unauthorized}
    end

    test "sibling-group role does NOT reach another subtree" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      {:ok, college} = Organizations.create_group(org, %{name: "College"})
      {:ok, eng} = Organizations.create_group(org, %{name: "Eng", parent_id: college.id})
      {:ok, arts} = Organizations.create_group(org, %{name: "Arts", parent_id: college.id})
      group_membership_fixture(eng, member, :admin)

      session = session_fixture(group: arts) |> Repo.reload()
      scope = Authz.load_subject(member)

      assert Authz.permit?(scope, :read, session) == {:error, :not_found}
    end

    test "a resource grant gives a visible-but-limited role" do
      owner = user_fixture()
      guest = user_fixture()
      session = session_fixture(user: owner) |> Repo.reload()
      session_grant_fixture(session, guest, :commenter)
      scope = Authz.load_subject(guest)

      assert Authz.permit?(scope, :comment, session) == :ok
      assert Authz.permit?(scope, :edit, session) == {:error, :unauthorized}
    end

    test "mutating decisions are logged; reads are not" do
      user = user_fixture()
      session = session_fixture(user: user) |> Repo.reload()
      scope = Authz.load_subject(user)

      Authz.permit?(scope, :read, session)
      assert Repo.aggregate(PerfectPaper.Authz.Decision, :count) == 0

      Authz.permit?(scope, :edit, session)
      assert Repo.aggregate(PerfectPaper.Authz.Decision, :count) == 1
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/perfect_paper/authz_test.exs`
Expected: FAIL — `Authz.permit?/3 is undefined`.

- [ ] **Step 3: Implement permit?/4 and helpers**

In `lib/perfect_paper/authz.ex`, add aliases and functions. Update the alias block to:

```elixir
  alias PerfectPaper.{Repo, Organizations}
  alias PerfectPaper.Accounts.Scope
  alias PerfectPaper.Authz.{Role, Decision, ResourceGrant}
  alias PerfectPaper.History.Session
```

Add:

```elixir
  @type action :: Role.action()
  @type decision :: :ok | {:error, :unauthorized} | {:error, :not_found}

  @doc """
  Whether `scope` may perform `action` on `resource`.

  Returns `:ok`; `{:error, :not_found}` when the subject has no line of sight at
  all (hide existence); `{:error, :unauthorized}` when the resource is visible
  but the subject's role is below the action's requirement. Mutating actions are
  recorded in `authz_decisions` (best-effort).
  """
  @spec permit?(Scope.t(), action(), Session.t(), map()) :: decision()
  def permit?(scope, action, resource, env \\ %{})

  def permit?(%Scope{} = scope, action, %Session{} = session, _env) do
    {role, reason} = effective_role(scope, session)

    decision =
      cond do
        is_nil(role) -> {:error, :not_found}
        Role.clears?(role, Role.required_for(action)) -> :ok
        true -> {:error, :unauthorized}
      end

    maybe_log(action, session, scope, decision, reason)
    decision
  end

  # Highest role the scope holds on the session, plus a reason tag, or {nil, nil}.
  defp effective_role(%Scope{user: %{id: uid}} = scope, %Session{} = session) do
    [
      owner_role(uid, session),
      group_role(uid, session),
      grant_role(uid, session)
    ]
    |> Enum.reject(&is_nil(elem(&1, 0)))
    |> case do
      [] -> {nil, nil}
      candidates -> Enum.max_by(candidates, fn {role, _} -> Role.rank(role) end)
    end
  end

  defp owner_role(uid, %Session{owner_type: :user, owner_id: uid}), do: {:owner, "owner"}
  defp owner_role(_uid, _session), do: {nil, nil}

  defp group_role(uid, %Session{owner_type: :group, owner_path: path}) when is_binary(path) do
    role =
      Repo.one(
        from m in Organizations.GroupMembership,
          join: g in Organizations.Group,
          on: g.id == m.group_id,
          where: m.user_id == ^uid and fragment("?::ltree @> ?::ltree", g.path, ^path),
          order_by: [desc: m.inserted_at],
          select: m.role,
          limit: 1
      )

    if role, do: {highest_membership_role(uid, path), "group_inheritance"}, else: {nil, nil}
  end

  defp group_role(_uid, _session), do: {nil, nil}

  # The strongest role among all ancestor (or equal) groups the user belongs to.
  defp highest_membership_role(uid, path) do
    Repo.all(
      from m in Organizations.GroupMembership,
        join: g in Organizations.Group,
        on: g.id == m.group_id,
        where: m.user_id == ^uid and fragment("?::ltree @> ?::ltree", g.path, ^path),
        select: m.role
    )
    |> Enum.max_by(&Role.rank/1, fn -> :viewer end)
  end

  defp grant_role(uid, %Session{id: sid}) do
    role =
      Repo.one(
        from grant in ResourceGrant,
          where:
            grant.resource_type == :session and grant.resource_id == ^sid and
              grant.subject_type == :user and grant.subject_id == ^uid,
          select: grant.role,
          limit: 1
      )

    if role, do: {role, "grant"}, else: {nil, nil}
  end

  defp maybe_log(action, %Session{} = session, %Scope{user: user}, decision, reason) do
    if Role.mutating?(action) do
      %Decision{}
      |> Decision.create_changeset(%{
        subject_id: user && user.id,
        action: to_string(action),
        resource_type: "session",
        resource_id: session.id,
        decision: decision_tag(decision),
        reason: reason
      })
      |> Repo.insert()
    end

    :ok
  end

  defp decision_tag(:ok), do: "ok"
  defp decision_tag({:error, reason}), do: to_string(reason)
```

Also add a public `rank/1` passthrough in `Role` since `effective_role` uses it — in `lib/perfect_paper/authz/role.ex`, change the private `rank/1` to public and spec it:

```elixir
  @doc "Numeric rank of a role on the ladder (0 = lowest). Public for max_by."
  @spec rank(t()) :: non_neg_integer()
  def rank(role), do: Enum.find_index(@ladder, &(&1 == role))
```

Update `clears?/2` (unchanged behavior, now calls the public `rank/1`).

- [ ] **Step 4: Simplify group_role (remove redundant query)**

`group_role/2` above queries twice. Replace it with a single resolution:

```elixir
  defp group_role(uid, %Session{owner_type: :group, owner_path: path}) when is_binary(path) do
    case highest_membership_role(uid, path) do
      nil -> {nil, nil}
      role -> {role, "group_inheritance"}
    end
  end

  defp group_role(_uid, _session), do: {nil, nil}

  # The strongest role among all ancestor-or-equal groups the user belongs to,
  # or nil when the user has no membership covering this path.
  defp highest_membership_role(uid, path) do
    Repo.all(
      from m in Organizations.GroupMembership,
        join: g in Organizations.Group,
        on: g.id == m.group_id,
        where: m.user_id == ^uid and fragment("?::ltree @> ?::ltree", g.path, ^path),
        select: m.role
    )
    |> case do
      [] -> nil
      roles -> Enum.max_by(roles, &Role.rank/1)
    end
  end
```

(`@>` means "is ancestor of, or equal to" — the owning path is a descendant-or-equal of the membership group's path, i.e. inheritance UP the tree.)

- [ ] **Step 5: Expose GroupMembership/Group to Authz via Organizations**

`Authz` references `Organizations.GroupMembership` and `Organizations.Group` schemas in queries. This is reading sibling schemas of another context for a query — acceptable here because `Authz` is the authorization boundary that must compose ownership across contexts, and it only reads. Confirm both modules are aliased/qualified (`Organizations.GroupMembership`, `Organizations.Group`) as written. No `Organizations.ex` change needed.

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/perfect_paper/authz_test.exs`
Expected: PASS (load_subject 2 + permit? 6 = 8 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/perfect_paper/authz.ex lib/perfect_paper/authz/role.ex test/perfect_paper/authz_test.exs
git commit -m "feat(authz): permit?/4 — owner/group-inheritance/grant resolution + audit log"
```

---

## Task 11: Authz.scope_query/3 — the list path

Narrows a `Session` query to what a subject may see (user-owned + group-owned via ltree). Grant-based list visibility deferred to Spec 2 (see Scope note).

**Files:**
- Modify: `lib/perfect_paper/authz.ex`
- Modify: `test/perfect_paper/authz_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/perfect_paper/authz_test.exs`:

```elixir
  describe "scope_query/3" do
    import PerfectPaper.HistoryFixtures
    alias PerfectPaper.History.Session

    test "returns only sessions the subject owns or inherits via a group" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      {:ok, college} = Organizations.create_group(org, %{name: "College"})
      {:ok, dept} = Organizations.create_group(org, %{name: "Dept", parent_id: college.id})
      group_membership_fixture(college, member, :viewer)

      mine = session_fixture(user: member)
      dept_doc = session_fixture(group: dept)
      _someone_elses = session_fixture()

      scope = Authz.load_subject(member)

      ids =
        Session
        |> Authz.scope_query(scope, :read)
        |> Repo.all()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert Enum.sort([mine.id, dept_doc.id]) == ids
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/perfect_paper/authz_test.exs`
Expected: FAIL — `Authz.scope_query/3 is undefined`.

- [ ] **Step 3: Implement scope_query/3**

In `lib/perfect_paper/authz.ex`, add:

```elixir
  @doc """
  Narrows a `Session` query to what `scope` may `:read`: sessions it owns
  directly, plus sessions owned by a group the subject inherits a role at
  (ltree descendant-or-equal of one of the subject's `group_paths`).

  Grant-based list visibility is added with the sharing flow (Spec 2).
  """
  @spec scope_query(Ecto.Queryable.t(), Scope.t(), :read) :: Ecto.Query.t()
  def scope_query(query, %Scope{user: %{id: uid}, group_paths: paths}, :read) do
    from s in query,
      where:
        (s.owner_type == :user and s.owner_id == ^uid) or
          (s.owner_type == :group and not is_nil(s.owner_path) and
             fragment("?::ltree <@ ANY(?::ltree[])", s.owner_path, ^paths))
  end
```

Note: when `paths` is empty, `ANY('{}'::ltree[])` is always false, so the group branch correctly matches nothing.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/perfect_paper/authz_test.exs`
Expected: PASS (all Authz tests).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/authz.ex test/perfect_paper/authz_test.exs
git commit -m "feat(authz): scope_query/3 narrows list reads to owned + inherited sessions"
```

---

## Task 12: Route History reads + mutations through Authz

Replace inline `s.user_id == ^user_id` with `Authz.scope_query/3` (lists/reads) and `Authz.permit?/4` (mutations). Functions take a `Scope` instead of a bare `user_id`.

**Files:**
- Modify: `lib/perfect_paper/history.ex`
- Modify: `test/perfect_paper/history_test.exs`

- [ ] **Step 1: Write the failing tests**

Append to `test/perfect_paper/history_test.exs`:

```elixir
  describe "scoped reads + mutations through Authz" do
    import PerfectPaper.HistoryFixtures
    alias PerfectPaper.Authz
    alias PerfectPaper.History

    test "list_sessions/1 returns only the subject's sessions" do
      user = PerfectPaper.AccountsFixtures.user_fixture()
      mine = session_fixture(user: user)
      _other = session_fixture()
      scope = Authz.load_subject(user)

      assert [%{id: id}] = History.list_sessions(scope)
      assert id == mine.id
    end

    test "get_session/2 returns nil for a session the subject can't see" do
      session = session_fixture()
      scope = Authz.load_subject(PerfectPaper.AccountsFixtures.user_fixture())

      assert History.get_session(session.id, scope) == nil
    end

    test "dismiss_comment/3 returns :unauthorized for a non-owner" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      comment = comment_fixture(session)
      scope = Authz.load_subject(PerfectPaper.AccountsFixtures.user_fixture())

      assert History.dismiss_comment(session.id, comment.id, by: scope) ==
               {:error, :not_found}
    end

    test "dismiss_comment/3 succeeds for the owner" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      comment = comment_fixture(session)
      scope = Authz.load_subject(owner)

      assert {:ok, %{comment: updated}} =
               History.dismiss_comment(session.id, comment.id, by: scope)

      assert updated.status == :dismissed
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: FAIL — `History.list_sessions/1` undefined (currently `/2` taking a user_id) etc.

- [ ] **Step 3: Update History reads**

In `lib/perfect_paper/history.ex`, update the alias and read functions.

Alias:

```elixir
  alias PerfectPaper.{Repo, Credits, Chatbot, Authz}
  alias PerfectPaper.Accounts.Scope
  alias PerfectPaper.History.{Session, Comment, CommentAction}
```

Replace `list_sessions/2`:

```elixir
  @doc "Lists the subject's visible sessions, newest first, comments preloaded."
  @spec list_sessions(Scope.t(), keyword()) :: [Session.t()]
  def list_sessions(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Session
    |> Authz.scope_query(scope, :read)
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> limit(^limit)
    |> preload(:comments)
    |> Repo.all()
  end
```

Replace `get_session/2`:

```elixir
  @doc """
  Fetches one session the subject may read, with comments preloaded, or `nil`.
  A session the subject can't see is indistinguishable from a missing one (404).
  """
  @spec get_session(Ecto.UUID.t(), Scope.t()) :: Session.t() | nil
  def get_session(id, %Scope{} = scope) do
    Session
    |> Authz.scope_query(scope, :read)
    |> where([s], s.id == ^id)
    |> preload(:comments)
    |> Repo.one()
  end
```

- [ ] **Step 4: Update process_session to keep working**

`process_session/2` calls `get_session(session.id, session.user_id)` at the end. Since processing acts on a session already loaded by its owner, reload by owner scope. Replace the final success branch and the helpers that used `session.user_id`:

In `process_session/2`, replace `{:ok, _changes} -> {:ok, get_session(session.id, session.user_id)}` with:

```elixir
        {:ok, _changes} -> {:ok, Repo.get(Session, session.id) |> Repo.preload(:comments)}
```

(Processing is an internal pipeline on an owned session; a direct reload is correct and avoids threading a scope through the LLM path. The entitlement/credit logic still keys off `session.owner_id` for user-owned sessions — see Step 5.)

- [ ] **Step 5: Key entitlement off owner_id**

`intended_level/1` and `charge_for_level/2` take a `user_id`. For user-owned sessions that's `session.owner_id`. Update `process_session/2`'s `with` head:

```elixir
    with {:ok, level} <- intended_level(session.owner_id),
         {:ok, review} <- Chatbot.review_document(document_text, level) do
      Multi.new()
      |> Multi.run(:charge, fn _repo, _changes -> charge_for_level(session.owner_id, level) end)
```

(Group-owned billing is Spec 4; for Spec 1, user-owned sessions charge their owner exactly as before.)

- [ ] **Step 6: Update mutations to authorize via permit?**

Replace `dismiss_comment/3`, `address_comment/3`, `undo_comment_action/4`, and `act_on_comment/4` to take a `Scope` and authorize with `Authz.permit?`:

```elixir
  @doc "Marks a comment dismissed (the writer chose to ignore it)."
  @spec dismiss_comment(Ecto.UUID.t(), Ecto.UUID.t(), [{:by, Scope.t()}]) ::
          {:ok, map()} | {:error, term()}
  def dismiss_comment(session_id, comment_id, by: %Scope{} = scope),
    do: act_on_comment(session_id, comment_id, scope, :dismiss)

  @doc "Marks a comment addressed (the writer applied the suggestion)."
  @spec address_comment(Ecto.UUID.t(), Ecto.UUID.t(), [{:by, Scope.t()}]) ::
          {:ok, map()} | {:error, term()}
  def address_comment(session_id, comment_id, by: %Scope{} = scope),
    do: act_on_comment(session_id, comment_id, scope, :address)
```

Replace `act_on_comment/4`:

```elixir
  # Acting on a comment is an :edit-level action on the session. Authorize via
  # Authz (not_found hides existence; unauthorized = visible but under-roled),
  # then record the action + move the comment in one transaction.
  defp act_on_comment(session_id, comment_id, %Scope{} = scope, action_type) do
    with %Session{} = session <- Repo.get(Session, session_id),
         :ok <- Authz.permit?(scope, :edit, session),
         %Comment{} = comment <-
           Repo.one(from c in Comment, where: c.id == ^comment_id and c.session_id == ^session_id) do
      attrs = %{
        session_id: session_id,
        comment_id: comment_id,
        user_id: scope.user.id,
        action_type: action_type
      }

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:action, CommentAction.create_changeset(%CommentAction{}, attrs))
      |> Ecto.Multi.update(:comment, Comment.apply_action_changeset(comment, action_type))
      |> Repo.transaction()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
```

Replace `undo_comment_action/4` to take a scope and authorize:

```elixir
  @doc "Undoes a dismiss/address, reverting the comment to open."
  @spec undo_comment_action(Ecto.UUID.t(), Ecto.UUID.t(), Scope.t(), Comment.action()) ::
          {:ok, map()} | {:error, term()}
  def undo_comment_action(session_id, comment_id, %Scope{} = scope, action_type) do
    with %Session{} = session <- Repo.get(Session, session_id),
         :ok <- Authz.permit?(scope, :edit, session),
         action when not is_nil(action) <-
           Repo.one(
             from a in CommentAction,
               where:
                 a.session_id == ^session_id and a.comment_id == ^comment_id and
                   a.action_type == ^action_type
           ),
         %Comment{} = comment <- Repo.get(Comment, comment_id) do
      Ecto.Multi.new()
      |> Ecto.Multi.delete(:action, action)
      |> Ecto.Multi.update(:comment, Comment.undo_action_changeset(comment, action_type))
      |> Repo.transaction()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
```

(The undo action is no longer keyed to a specific `user_id` — any editor of the session may undo, which matches the role model. The recorded action's `user_id` remains for attribution.)

- [ ] **Step 7: Run tests to verify they pass**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: PASS. Fix any older test in this file still calling `list_sessions(user_id)`/`get_session(id, user_id)`/`dismiss_comment(.., by: user_id)` — update them to pass `Authz.load_subject(user)`.

- [ ] **Step 8: Commit**

```bash
git add lib/perfect_paper/history.ex test/perfect_paper/history_test.exs
git commit -m "refactor(history): authorize reads/mutations via Authz (no inline user_id ==)"
```

---

## Task 13: Wire the controller + FallbackController (404 vs 403)

The reference REST controller builds a scope and maps `Authz` results: no line of sight → 404, visible-but-under-roled → 403.

**Files:**
- Modify: `lib/perfect_paper_web/controllers/api/fallback_controller.ex`
- Modify: `lib/perfect_paper_web/controllers/api/history_controller.ex`
- Modify: `test/perfect_paper_web/controllers/api/history_controller_test.exs`

- [ ] **Step 1: Write the failing tests**

Append to `test/perfect_paper_web/controllers/api/history_controller_test.exs` (inside the module; it uses `setup :register_and_log_in_user`, exposing `conn` + `user`):

```elixir
  describe "authorization status codes" do
    import PerfectPaper.HistoryFixtures

    test "GET show on another user's session is 404 (existence hidden)", %{conn: conn} do
      other = session_fixture()
      conn = get(conn, ~p"/api/history/#{other.id}")
      assert json_response(conn, 404)
    end

    test "dismiss on a visible-but-under-roled session is 403", %{conn: conn, user: user} do
      # Share a session with the logged-in user as a commenter (can see, can't edit).
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      comment = comment_fixture(session)
      PerfectPaper.AuthzFixtures.session_grant_fixture(session, user, :commenter)

      conn = post(conn, ~p"/api/history/#{session.id}/comments/#{comment.id}/dismiss")
      assert json_response(conn, 403)
    end
  end
```

(If the exact route helpers differ, match the existing tests in this file — reuse their `~p"/api/..."` paths.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/perfect_paper_web/controllers/api/history_controller_test.exs`
Expected: FAIL — show returns the old behavior / dismiss returns 400, not 403.

- [ ] **Step 3: Map :unauthorized in FallbackController**

In `lib/perfect_paper_web/controllers/api/fallback_controller.ex`, add a clause **above** the catch-all `call(conn, {:error, _other})`:

```elixir
  def call(conn, {:error, :unauthorized}), do: detail(conn, 403, "Forbidden")
```

(`{:error, :not_found}` already maps to 404; that's the no-line-of-sight case.)

- [ ] **Step 4: Build a scope in the controller**

In `lib/perfect_paper_web/controllers/api/history_controller.ex`, add the alias and a private helper, and route every action through the scope.

Add after `alias PerfectPaper.History`:

```elixir
  alias PerfectPaper.Authz
```

Add at the bottom (before the final `end`):

```elixir
  defp scope(conn), do: Authz.load_subject(conn.assigns.current_user)
```

Update the actions:

```elixir
  def index(conn, _params) do
    sessions = History.list_sessions(scope(conn))
    render(conn, :index, sessions: sessions)
  end

  def show(conn, %{"id" => id}) do
    case History.get_session(id, scope(conn)) do
      nil -> {:error, :not_found}
      session -> render(conn, :show, session: session)
    end
  end

  def delete(conn, %{"id" => id}) do
    s = scope(conn)

    with %History.Session{} = session <- History.get_session(id, s),
         {:ok, _} <- History.delete_session(session) do
      send_resp(conn, :no_content, "")
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  def dismiss(conn, %{"session_id" => sid, "comment_id" => cid}) do
    with {:ok, %{comment: comment}} <-
           History.dismiss_comment(sid, cid, by: scope(conn)) do
      render(conn, :comment, comment: comment)
    end
  end

  def address(conn, %{"session_id" => sid, "comment_id" => cid}) do
    with {:ok, %{comment: comment}} <-
           History.address_comment(sid, cid, by: scope(conn)) do
      render(conn, :comment, comment: comment)
    end
  end

  def set_visibility(conn, %{"id" => id} = params) do
    s = scope(conn)

    with %History.Session{} = session <- History.get_session(id, s),
         {:ok, updated} <- History.set_visibility(session, truthy?(params["is_public"])) do
      render(conn, :show, session: updated)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  def mark_viewed(conn, %{"id" => id}) do
    s = scope(conn)

    with %History.Session{} = session <- History.get_session(id, s),
         {:ok, updated} <- History.mark_viewed(session) do
      render(conn, :show, session: updated)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/perfect_paper_web/controllers/api/history_controller_test.exs`
Expected: PASS. Fix any older controller test that asserted the previous single-owner shape.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/controllers/api/fallback_controller.ex lib/perfect_paper_web/controllers/api/history_controller.ex test/perfect_paper_web/controllers/api/history_controller_test.exs
git commit -m "feat(web): History controller builds scope; FallbackController maps :unauthorized → 403"
```

---

## Task 14: Pre-merge verification

Full-suite check (the one time the full suite runs, per CLAUDE.md).

- [ ] **Step 1: Run the LiveView History callers (if any) compile**

Run: `mix compile --warnings-as-errors`
Expected: no warnings. If `lib/perfect_paper_web/live/history_live/*` calls `History.list_sessions(user_id)` / `get_session(id, user_id)` / `dismiss_comment(.., by: user_id)`, update them to build a scope (`Authz.load_subject(socket.assigns.current_scope.user)` or `Authz.load_subject(current_user)`), mirroring the controller. Re-run until clean.

- [ ] **Step 2: Run the full precommit**

Run: `mix precommit`
Expected: PASS — compile (warnings as errors), deps.unlock --unused, format, and the full test suite all green.

- [ ] **Step 3: Commit any fixups**

```bash
git add -A
git commit -m "chore: fix up LiveView History callers for scoped Authz API"
```

(Skip if Step 1/2 produced no changes.)

---

## Self-review (completed during plan authoring)

**Spec coverage:**
- Nested groups + ltree + GiST index → Task 2 (+ Task 4 path computation). ✓
- Polymorphic ownership + backfill (expand/contract, no drop, `mix`-style data step not Oban) → Task 5. ✓
- resource_grants → Task 7. ✓
- Authz choke point: `permit?/4` (owner/group-inheritance-up-the-tree/grant), role ladder, decision log (mutations only), default-deny, 404-vs-403 split → Tasks 1, 8, 10, 13. ✓
- `scope_query/3` list path → Task 11. ✓
- History routed through Authz (no inline `user_id ==`) → Task 12. ✓
- Reference controller 404/403 → Task 13. ✓
- Tests for all of the above → each task. ✓
- Documents columns (forward-compat, no context refactor) → Task 5 + Scope note. ✓ (deliberate, stated)
- Grant-based list visibility deferred → Scope note + Task 11 doc. ✓ (deliberate, stated)

**Placeholder scan:** none — every code step shows full code.

**Type consistency:** `permit?/4` arity + `decision` type, `scope_query/3` `:read`, `Role.required_for/1`/`clears?/2`/`mutating?/1`/`rank/1`, `Authz.load_subject/1`, `Scope{user, group_paths}`, `Session` ownership fields, and the `by: %Scope{}` keyword on dismiss/address are used identically across Tasks 1, 9, 10, 11, 12, 13. The ltree operators are consistent: `@>` (ancestor-or-equal, in `permit?` resolution) and `<@ ANY(...)` (descendant-or-equal of any, in `scope_query`). ✓
