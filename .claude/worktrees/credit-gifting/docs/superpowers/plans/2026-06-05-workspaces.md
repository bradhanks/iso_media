# Workspaces v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Notion/Attio-style workspaces — a default Personal workspace per account plus user-created ones, a sidebar-header switcher, and reviews scoped to the active workspace encoded in the URL (`/w/:workspace_id/…`).

**Architecture:** A new standalone `PerfectPaper.Workspaces` context + `workspaces` table, orthogonal to the enterprise `Organizations` layer. The active workspace is the URL (tab-isolated, bookmarkable); `users.active_workspace_id` is only a last-used landing default. Reviews gain a `workspace_id`. A `:assign_workspace` on_mount hook assigns `@current_workspace` + `@workspaces` on every authenticated page (scoped or global). Personal workspaces are created lazily and race-safely.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto/PostgreSQL (binary_id), LiveView, daisyUI. Tests: ExUnit `DataCase`/`ConnCase`/`LiveViewTest`.

**Spec:** `docs/superpowers/specs/2026-06-05-workspaces-design.md`

**Branch:** create a fresh feature branch off `main` before Task 1 (`git checkout main && git checkout -b feat/workspaces`).

---

## File structure

- Create `lib/perfect_paper/workspaces/workspace.ex` — schema + changesets.
- Create `lib/perfect_paper/workspaces.ex` — context (sole Repo boundary).
- Create migrations: `*_create_workspaces.exs` (schema), `*_backfill_workspaces.exs` (data).
- Modify `lib/perfect_paper/accounts/user.ex` — add `active_workspace_id` field.
- Modify `lib/perfect_paper/history/session.ex` — add `workspace_id` field + cast.
- Modify `lib/perfect_paper/history.ex` — `workspace_id:` filter + `reassign_reviews/2`.
- Modify `lib/perfect_paper_web/user_auth.ex` — `:assign_workspace` on_mount.
- Create `lib/perfect_paper_web/controllers/workspace_redirect_controller.ex`.
- Rename `lib/perfect_paper_web/live/workspace_live.ex` → `reading_room_live.ex` (`WorkspaceLive` → `ReadingRoomLive`).
- Modify `lib/perfect_paper_web/router.ex` — `/w/:workspace_id/…` routes + redirects.
- Modify `lib/perfect_paper_web/live/new_live.ex` — set `workspace_id`, navigate to reading room.
- Modify `lib/perfect_paper_web/live/history_live/index.ex` (+ `.html.heex`) — scope by workspace.
- Create `lib/perfect_paper_web/components/workspace_switcher.ex` — LiveComponent.
- Modify `lib/perfect_paper_web/components/app_shell.ex` — render switcher; rename nav "History"→"Reviews".

Run targeted tests only while developing (e.g. `mix test test/perfect_paper/workspaces_test.exs`). Use `MIX_TEST_PARTITION=<unique>` to avoid colliding with parallel sessions on the shared test DB.

---

### Task 1: Migration A — schema (workspaces table + columns)

**Files:**
- Create: `priv/repo/migrations/<generated>_create_workspaces.exs`

- [ ] **Step 1: Generate the migration file**

Run: `mix ecto.gen.migration create_workspaces`
This prints the created path; edit that file in the next step.

- [ ] **Step 2: Write the migration body**

```elixir
defmodule PerfectPaper.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :is_personal, :boolean, null: false, default: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create index(:workspaces, [:user_id])

    # At most one Personal workspace per user.
    create unique_index(:workspaces, [:user_id],
             where: "is_personal",
             name: :workspaces_one_personal_per_user
           )

    alter table(:history_sessions) do
      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict)
    end

    create index(:history_sessions, [:workspace_id])

    alter table(:users) do
      add :active_workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `mix ecto.migrate`
Expected: creates `workspaces`, adds `history_sessions.workspace_id` and `users.active_workspace_id`, no errors.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations
git commit -m "feat(workspaces): migration A — workspaces table + scoping columns"
```

---

### Task 2: Workspace schema + changesets

**Files:**
- Create: `lib/perfect_paper/workspaces/workspace.ex`
- Test: `test/perfect_paper/workspaces/workspace_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule PerfectPaper.Workspaces.WorkspaceTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Workspaces.Workspace

  test "create_changeset trims name and requires user_id + name" do
    uid = Ecto.UUID.generate()
    cs = Workspace.create_changeset(%Workspace{}, %{name: "  Thesis  ", user_id: uid})
    assert cs.valid?
    assert Ecto.Changeset.get_change(cs, :name) == "Thesis"

    refute Workspace.create_changeset(%Workspace{}, %{name: "x"}).valid?
    refute Workspace.create_changeset(%Workspace{}, %{user_id: uid, name: "   "}).valid?
  end

  test "personal_changeset marks is_personal and names it Personal" do
    user = %PerfectPaper.Accounts.User{id: Ecto.UUID.generate()}
    cs = Workspace.personal_changeset(user)
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :is_personal) == true
    assert Ecto.Changeset.get_field(cs, :name) == "Personal"
    assert Ecto.Changeset.get_field(cs, :user_id) == user.id
  end

  test "rename_changeset trims and rejects blank" do
    cs = Workspace.rename_changeset(%Workspace{name: "Old"}, %{name: "  New  "})
    assert Ecto.Changeset.get_change(cs, :name) == "New"
    refute Workspace.rename_changeset(%Workspace{name: "Old"}, %{name: "  "}).valid?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/perfect_paper/workspaces/workspace_test.exs`
Expected: FAIL — module `PerfectPaper.Workspaces.Workspace` not loaded.

- [ ] **Step 3: Write the schema**

```elixir
defmodule PerfectPaper.Workspaces.Workspace do
  @moduledoc """
  A workspace: a lightweight, user-owned container that groups a user's reviews.
  Distinct from the enterprise `Organizations` tenant. Each user has exactly one
  Personal workspace (`is_personal: true`) plus any they create.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Accounts.User

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workspaces" do
    field :name, :string
    field :is_personal, :boolean, default: false
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a user-created workspace."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :user_id])
    |> update_change(:name, &trim/1)
    |> validate_required([:name, :user_id])
    |> validate_length(:name, min: 1, max: 120)
  end

  @doc "Changeset for the user's auto-created Personal workspace."
  @spec personal_changeset(User.t()) :: Ecto.Changeset.t()
  def personal_changeset(%User{id: user_id}) do
    %__MODULE__{}
    |> cast(%{name: "Personal", user_id: user_id, is_personal: true}, [
      :name,
      :user_id,
      :is_personal
    ])
    |> validate_required([:name, :user_id])
  end

  @doc "Changeset for renaming a workspace."
  @spec rename_changeset(t(), map()) :: Ecto.Changeset.t()
  def rename_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name])
    |> update_change(:name, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/perfect_paper/workspaces/workspace_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/workspaces/workspace.ex test/perfect_paper/workspaces/workspace_test.exs
git commit -m "feat(workspaces): Workspace schema + changesets"
```

---

### Task 3: Workspaces context

> **Execution order:** this task's `set_active` test needs `users.active_workspace_id`
> (Task 4) and its `delete_workspace` test needs `History.reassign_reviews/2`
> (Task 5). When executing linearly, **complete Tasks 4 and 5 before greening
> Task 3**. (Write Task 3's code in place; run its full test suite green only
> after 4 and 5 land.)

**Files:**
- Create: `lib/perfect_paper/workspaces.ex`
- Test: `test/perfect_paper/workspaces_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule PerfectPaper.WorkspacesTest do
  use PerfectPaper.DataCase, async: true

  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Workspaces
  alias PerfectPaper.Workspaces.Workspace

  test "personal_workspace creates once and is idempotent" do
    user = user_fixture()
    a = Workspaces.personal_workspace(user)
    b = Workspaces.personal_workspace(user)
    assert a.id == b.id
    assert a.is_personal
    assert a.name == "Personal"
  end

  test "personal_workspace is concurrency-safe" do
    user = user_fixture()

    ids =
      1..5
      |> Task.async_stream(fn _ -> Workspaces.personal_workspace(user).id end,
        max_concurrency: 5
      )
      |> Enum.map(fn {:ok, id} -> id end)
      |> Enum.uniq()

    assert length(ids) == 1
  end

  test "list_workspaces returns Personal first, then by name" do
    user = user_fixture()
    Workspaces.personal_workspace(user)
    {:ok, _} = Workspaces.create_workspace(user, %{name: "Zeta"})
    {:ok, _} = Workspaces.create_workspace(user, %{name: "Alpha"})
    names = user |> Workspaces.list_workspaces() |> Enum.map(& &1.name)
    assert names == ["Personal", "Alpha", "Zeta"]
  end

  test "create_workspace is owned by the user; get/rename enforce ownership" do
    user = user_fixture()
    other = user_fixture()
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "Lab"})
    assert ws.user_id == user.id

    assert {:ok, ^ws} = Workspaces.get_workspace(ws.id, user)
    assert {:error, :not_found} = Workspaces.get_workspace(ws.id, other)
    assert {:error, :not_found} = Workspaces.get_workspace("not-a-uuid", user)

    assert {:ok, renamed} = Workspaces.rename_workspace(ws, user, "Renamed Lab")
    assert renamed.name == "Renamed Lab"
    assert {:error, :not_found} = Workspaces.rename_workspace(ws, other, "Hijack")
  end

  test "delete_workspace refuses Personal and rejects non-owners" do
    user = user_fixture()
    other = user_fixture()
    personal = Workspaces.personal_workspace(user)
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "Temp"})

    assert {:error, :personal} = Workspaces.delete_workspace(personal, user)
    assert {:error, :not_found} = Workspaces.delete_workspace(ws, other)
    assert {:ok, _} = Workspaces.delete_workspace(ws, user)
    assert {:error, :not_found} = Workspaces.get_workspace(ws.id, user)
  end

  test "set_active persists only a workspace the user owns" do
    user = user_fixture()
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "W"})
    assert {:ok, updated} = Workspaces.set_active(user, ws.id)
    assert updated.active_workspace_id == ws.id
    assert {:error, :not_found} = Workspaces.set_active(user, Ecto.UUID.generate())
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/perfect_paper/workspaces_test.exs`
Expected: FAIL — `PerfectPaper.Workspaces` not loaded.

- [ ] **Step 3: Write the context**

```elixir
defmodule PerfectPaper.Workspaces do
  @moduledoc """
  Workspaces — a user's lightweight, switchable containers for grouping reviews.
  This is the public API and the only `Repo` boundary for workspaces. Every
  function authorizes on `workspace.user_id == user.id` (v1 is solo; membership
  comes later).
  """
  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.Accounts.User
  alias PerfectPaper.Workspaces.Workspace

  @doc "The user's workspaces, Personal pinned first, then alphabetical."
  @spec list_workspaces(User.t()) :: [Workspace.t()]
  def list_workspaces(%User{id: uid}) do
    Repo.all(
      from w in Workspace,
        where: w.user_id == ^uid,
        order_by: [desc: w.is_personal, asc: w.name]
    )
  end

  @doc """
  Ensure-and-return the user's Personal workspace. Concurrency-safe: if a
  parallel request wins the insert, we re-read the existing row instead of
  raising on the partial unique index.
  """
  @spec personal_workspace(User.t()) :: Workspace.t()
  def personal_workspace(%User{} = user) do
    case Repo.get_by(Workspace, user_id: user.id, is_personal: true) do
      %Workspace{} = ws -> ws
      nil -> insert_personal(user)
    end
  end

  defp insert_personal(user) do
    case user |> Workspace.personal_changeset() |> Repo.insert() do
      {:ok, ws} -> ws
      {:error, _changeset} -> Repo.get_by!(Workspace, user_id: user.id, is_personal: true)
    end
  end

  @doc "Fetch a workspace the user owns (hides existence otherwise)."
  @spec get_workspace(Ecto.UUID.t(), User.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def get_workspace(id, %User{id: uid}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get_by(Workspace, id: uuid, user_id: uid) do
          %Workspace{} = ws -> {:ok, ws}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc "Create a (non-personal) workspace owned by the user."
  @spec create_workspace(User.t(), map()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(%User{} = user, attrs) do
    %Workspace{}
    |> Workspace.create_changeset(Map.put(Map.new(attrs), :user_id, user.id))
    |> Repo.insert()
  end

  @doc "Rename a workspace the user owns (Personal allowed)."
  @spec rename_workspace(Workspace.t(), User.t(), String.t()) ::
          {:ok, Workspace.t()} | {:error, term()}
  def rename_workspace(%Workspace{user_id: uid} = ws, %User{id: uid}, name) do
    ws |> Workspace.rename_changeset(%{name: name}) |> Repo.update()
  end

  def rename_workspace(%Workspace{}, %User{}, _name), do: {:error, :not_found}

  @doc """
  Delete a non-Personal workspace the user owns. Its reviews are first reassigned
  to the user's Personal workspace (via `History.reassign_reviews/2` — History
  owns the sessions table), then the workspace row is deleted.
  """
  @spec delete_workspace(Workspace.t(), User.t()) ::
          {:ok, Workspace.t()} | {:error, :personal | :not_found | term()}
  def delete_workspace(%Workspace{is_personal: true}, %User{}), do: {:error, :personal}

  def delete_workspace(%Workspace{user_id: uid} = ws, %User{id: uid} = user) do
    personal = personal_workspace(user)
    {:ok, _count} = PerfectPaper.History.reassign_reviews(ws.id, personal.id)
    Repo.delete(ws)
  end

  def delete_workspace(%Workspace{}, %User{}), do: {:error, :not_found}

  @doc "Persist the user's last-used workspace default (must own it)."
  @spec set_active(User.t(), Ecto.UUID.t()) :: {:ok, User.t()} | {:error, :not_found}
  def set_active(%User{} = user, workspace_id) do
    case get_workspace(workspace_id, user) do
      {:ok, ws} ->
        user
        |> Ecto.Changeset.change(active_workspace_id: ws.id)
        |> Repo.update()

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
```

- [ ] **Step 4: Run the test (after Tasks 4 and 5 are in place)**

Run: `mix test test/perfect_paper/workspaces_test.exs`
Expected: PASS. Per the execution-order note above, `set_active` needs the
`users.active_workspace_id` field (Task 4) and `delete_workspace` needs
`History.reassign_reviews/2` (Task 5); with both present, all tests green.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/workspaces.ex test/perfect_paper/workspaces_test.exs
git commit -m "feat(workspaces): Workspaces context (list/get/create/rename/delete/personal/set_active)"
```

---

### Task 4: User schema — `active_workspace_id` field

**Files:**
- Modify: `lib/perfect_paper/accounts/user.ex:34` (after `field :locale`)

- [ ] **Step 1: Add the field**

In the `schema "users" do` block, after `field :locale, :string, default: "en"`:

```elixir
    field :active_workspace_id, :binary_id
```

- [ ] **Step 2: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 3: Commit**

```bash
git add lib/perfect_paper/accounts/user.ex
git commit -m "feat(workspaces): users.active_workspace_id field"
```

---

### Task 5: Session `workspace_id` + History filter + `reassign_reviews/2`

**Files:**
- Modify: `lib/perfect_paper/history/session.ex` (field + cast)
- Modify: `lib/perfect_paper/history.ex` (filter option + `reassign_reviews/2`)
- Test: `test/perfect_paper/history_test.exs` (append)

- [ ] **Step 1: Write the failing test (append to history_test.exs)**

```elixir
  describe "workspace scoping" do
    setup do
      import PerfectPaper.AccountsFixtures
      user = user_fixture()
      # Insert workspace rows directly so this task does not depend on the
      # Workspaces context (Task 5 lands before Task 3 in execution order).
      ws_a =
        PerfectPaper.Repo.insert!(%PerfectPaper.Workspaces.Workspace{
          name: "A",
          user_id: user.id
        })

      ws_b =
        PerfectPaper.Repo.insert!(%PerfectPaper.Workspaces.Workspace{
          name: "B",
          user_id: user.id
        })

      scope = PerfectPaper.Authz.load_subject(user)
      %{user: user, ws_a: ws_a, ws_b: ws_b, scope: scope}
    end

    test "begin_session stores workspace_id; list filters by it", ctx do
      {:ok, _a} =
        PerfectPaper.History.begin_session(%{
          user_id: ctx.user.id,
          title: "in A",
          workspace_id: ctx.ws_a.id
        })

      {:ok, _b} =
        PerfectPaper.History.begin_session(%{
          user_id: ctx.user.id,
          title: "in B",
          workspace_id: ctx.ws_b.id
        })

      titles_a =
        ctx.scope
        |> PerfectPaper.History.list_session_summaries(workspace_id: ctx.ws_a.id)
        |> Enum.map(& &1.title)

      assert titles_a == ["in A"]
    end

    test "reassign_reviews moves sessions to the target workspace", ctx do
      {:ok, s} =
        PerfectPaper.History.begin_session(%{
          user_id: ctx.user.id,
          title: "moving",
          workspace_id: ctx.ws_a.id
        })

      assert {:ok, 1} = PerfectPaper.History.reassign_reviews(ctx.ws_a.id, ctx.ws_b.id)
      assert PerfectPaper.Repo.reload!(s).workspace_id == ctx.ws_b.id
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: FAIL — `workspace_id` not cast / `reassign_reviews/2` undefined.

- [ ] **Step 3: Add `workspace_id` to the Session schema + cast**

In `lib/perfect_paper/history/session.ex`, add to the schema block (after `field :document_id, :binary_id`):

```elixir
    field :workspace_id, :binary_id
```

And add `:workspace_id` to the `cast/3` list in `create_changeset`:

```elixir
    |> cast(attrs, [
      :title,
      :user_id,
      :processing_status,
      :owner_type,
      :owner_id,
      :organization_id,
      :owner_path,
      :document_id,
      :workspace_id
    ])
```

- [ ] **Step 4: Add the filter option + `reassign_reviews/2` to History**

In `lib/perfect_paper/history.ex`, change `list_session_summaries/2`'s `base` to apply an optional workspace filter:

```elixir
  def list_session_summaries(%Scope{} = scope, opts \\ []) do
    base =
      Session
      |> Authz.scope_query(scope, :read)
      |> maybe_filter_workspace(Keyword.get(opts, :workspace_id))
      |> order_by([s], desc: s.inserted_at, desc: s.id)
      |> limit(^Keyword.get(opts, :limit, 50))

    from(s in base,
      left_join: c in assoc(s, :comments),
      group_by: s.id,
      select: %{s | comments_count: count(c.id)}
    )
    |> Repo.all()
  end

  defp maybe_filter_workspace(query, nil), do: query
  defp maybe_filter_workspace(query, ws_id), do: where(query, [s], s.workspace_id == ^ws_id)
```

Add `reassign_reviews/2` (History owns the sessions table; Workspaces calls this):

```elixir
  @doc "Moves every review in `from_workspace_id` to `to_workspace_id`. Returns {:ok, count}."
  @spec reassign_reviews(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def reassign_reviews(from_workspace_id, to_workspace_id) do
    {count, _} =
      from(s in Session, where: s.workspace_id == ^from_workspace_id)
      |> Repo.update_all(set: [workspace_id: to_workspace_id])

    {:ok, count}
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: PASS (plus existing history tests stay green).

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/history/session.ex lib/perfect_paper/history.ex test/perfect_paper/history_test.exs
git commit -m "feat(workspaces): session workspace_id + History filter & reassign_reviews"
```

---

### Task 6: Migration B — backfill (set-based)

**Files:**
- Create: `priv/repo/migrations/<generated>_backfill_workspaces.exs`
- Test: `test/perfect_paper/repo/backfill_workspaces_test.exs`

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration backfill_workspaces`

- [ ] **Step 2: Write the migration body (set-based SQL, no loop)**

```elixir
defmodule PerfectPaper.Repo.Migrations.BackfillWorkspaces do
  use Ecto.Migration

  def up do
    # 1) One Personal workspace per existing user that lacks one.
    execute """
    INSERT INTO workspaces (id, name, is_personal, user_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'Personal', true, u.id, now(), now()
    FROM users u
    WHERE NOT EXISTS (
      SELECT 1 FROM workspaces w WHERE w.user_id = u.id AND w.is_personal
    )
    """

    # 2) Stamp existing user-owned sessions with that user's Personal workspace.
    execute """
    UPDATE history_sessions s
    SET workspace_id = w.id
    FROM workspaces w
    WHERE w.user_id = s.owner_id
      AND w.is_personal
      AND s.owner_type = 'user'
      AND s.workspace_id IS NULL
    """

    # 3) Default each user's last-used workspace to Personal.
    execute """
    UPDATE users u
    SET active_workspace_id = w.id
    FROM workspaces w
    WHERE w.user_id = u.id
      AND w.is_personal
      AND u.active_workspace_id IS NULL
    """
  end

  def down do
    execute "UPDATE users SET active_workspace_id = NULL"
    execute "UPDATE history_sessions SET workspace_id = NULL"
    execute "DELETE FROM workspaces WHERE is_personal"
  end
end
```

- [ ] **Step 3: Write the failing test**

```elixir
defmodule PerfectPaper.Repo.BackfillWorkspacesTest do
  use PerfectPaper.DataCase, async: true

  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.{Repo, Workspaces, History}

  test "every user has a Personal workspace and their sessions are stamped" do
    user = user_fixture()
    {:ok, s} = History.begin_session(%{user_id: user.id, title: "legacy"})
    # Simulate a pre-backfill row.
    Repo.update_all(
      from(x in "history_sessions", where: x.id == type(^s.id, :binary_id)),
      set: [workspace_id: nil]
    )

    Ecto.Migrator.run(Repo, :up, all: true)

    personal = Workspaces.personal_workspace(user)
    assert personal.is_personal
    assert Repo.reload!(s).workspace_id == personal.id
    assert Repo.reload!(user).active_workspace_id == personal.id
  end
end
```

NOTE: in the sandboxed `DataCase`, the migration already ran at suite setup, so this test mostly asserts the backfill SQL is idempotent and correct against fixtures. If `Ecto.Migrator.run` is awkward under the sandbox, instead assert the three SQL statements directly via `Repo.query!` of the same SQL. Prefer the direct-SQL assertion if the migrator call errors under `async: true`.

- [ ] **Step 4: Run migration + test**

Run: `mix ecto.migrate` then `mix test test/perfect_paper/repo/backfill_workspaces_test.exs`
Expected: migrate succeeds; test PASS.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations test/perfect_paper/repo/backfill_workspaces_test.exs
git commit -m "feat(workspaces): migration B — set-based backfill of Personal workspaces"
```

---

### Task 7: `:assign_workspace` on_mount hook

**Files:**
- Modify: `lib/perfect_paper_web/user_auth.ex` (add `on_mount(:assign_workspace, …)`)
- Test: `test/perfect_paper_web/user_auth_workspace_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule PerfectPaperWeb.UserAuthWorkspaceTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures
  alias PerfectPaperWeb.UserAuth
  alias PerfectPaper.Workspaces

  defp socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: PerfectPaper.Accounts.Scope.for_user(user)}
    }
  end

  test "global mode (no :workspace_id) assigns Personal as current + the list" do
    user = user_fixture()
    {:cont, socket} = UserAuth.on_mount(:assign_workspace, %{}, %{}, socket(user))
    assert socket.assigns.current_workspace.is_personal
    assert is_list(socket.assigns.workspaces)
  end

  test "scoped mode assigns the URL workspace when owned" do
    user = user_fixture()
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "Lab"})

    {:cont, socket} =
      UserAuth.on_mount(:assign_workspace, %{"workspace_id" => ws.id}, %{}, socket(user))

    assert socket.assigns.current_workspace.id == ws.id
  end

  test "scoped mode redirects when the workspace isn't the user's" do
    user = user_fixture()
    other = user_fixture()
    {:ok, ws} = Workspaces.create_workspace(other, %{name: "NotYours"})

    assert {:halt, _socket} =
             UserAuth.on_mount(:assign_workspace, %{"workspace_id" => ws.id}, %{}, socket(user))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/perfect_paper_web/user_auth_workspace_test.exs`
Expected: FAIL — `on_mount(:assign_workspace, …)` clause not defined.

- [ ] **Step 3: Implement the hook**

Add to `lib/perfect_paper_web/user_auth.ex` (near the other `on_mount/4` clauses), and add `alias PerfectPaper.Workspaces` at the top if absent:

```elixir
  @doc """
  Assigns `@current_workspace` and `@workspaces` on every authenticated page.

  Scoped routes (`/w/:workspace_id/…`) resolve the URL workspace (redirecting if
  it isn't the user's). Global routes resolve the user's last-used/Personal
  default so the sidebar switcher + nav links always have their assigns.
  """
  def on_mount(:assign_workspace, params, _session, socket) do
    user = socket.assigns.current_scope.user
    workspaces = Workspaces.list_workspaces(user)

    case params do
      %{"workspace_id" => id} ->
        case Workspaces.get_workspace(id, user) do
          {:ok, ws} ->
            _ = Workspaces.set_active(user, ws.id)

            {:cont,
             socket
             |> Phoenix.Component.assign(:current_workspace, ws)
             |> Phoenix.Component.assign(:workspaces, workspaces)}

          {:error, :not_found} ->
            default = default_workspace(user)

            {:halt,
             Phoenix.LiveView.redirect(socket, to: "/w/#{default.id}/reviews")}
        end

      _ ->
        {:cont,
         socket
         |> Phoenix.Component.assign(:current_workspace, default_workspace(user))
         |> Phoenix.Component.assign(:workspaces, workspaces)}
    end
  end

  defp default_workspace(user) do
    with id when is_binary(id) <- user.active_workspace_id,
         {:ok, ws} <- Workspaces.get_workspace(id, user) do
      ws
    else
      _ -> Workspaces.personal_workspace(user)
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/perfect_paper_web/user_auth_workspace_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/user_auth.ex test/perfect_paper_web/user_auth_workspace_test.exs
git commit -m "feat(workspaces): :assign_workspace on_mount (scoped + global mode)"
```

---

### Task 8: Rename `WorkspaceLive` → `ReadingRoomLive` + canonicalize

**Files:**
- Rename: `lib/perfect_paper_web/live/workspace_live.ex` → `lib/perfect_paper_web/live/reading_room_live.ex`
- Rename: `test/perfect_paper_web/live/workspace_live_test.exs` → `reading_room_live_test.exs`

- [ ] **Step 1: Move the files with git**

```bash
git mv lib/perfect_paper_web/live/workspace_live.ex lib/perfect_paper_web/live/reading_room_live.ex
git mv test/perfect_paper_web/live/workspace_live_test.exs test/perfect_paper_web/live/reading_room_live_test.exs
```

- [ ] **Step 2: Rename the module + references**

In `reading_room_live.ex`, change `defmodule PerfectPaperWeb.WorkspaceLive do` to `defmodule PerfectPaperWeb.ReadingRoomLive do`. In `reading_room_live_test.exs`, change `PerfectPaperWeb.WorkspaceLiveTest` → `PerfectPaperWeb.ReadingRoomLiveTest`. Update any `~p"/workspace/#{...}"` paths in the test to `~p"/w/#{workspace_id}/review/#{id}"` (the route changes in Task 9; the test's session needs a `workspace_id` — set one via a created workspace in setup).

Update the Download-menu export hrefs (around `reading_room_live.ex:144-150`) from the old path to the new workspace-scoped export route:

```elixir
<a href={~p"/w/#{@session.workspace_id}/review/#{@session.id}/export/docx"} class="font-sans text-sm">
  Download as DOCX
</a>
<a href={~p"/w/#{@session.workspace_id}/review/#{@session.id}/export/markdown"} class="font-sans text-sm">
  Download as Markdown
</a>
```

Add canonicalization to `mount/3`: after loading the session, if `session.workspace_id` doesn't match the `:workspace_id` URL param, redirect to the canonical URL:

```elixir
    # ...after fetching `session`:
    socket =
      if connected?(socket) and session.workspace_id &&
           session.workspace_id != params["workspace_id"] do
        push_navigate(socket, to: ~p"/w/#{session.workspace_id}/review/#{session.id}")
      else
        socket
      end
```

(Adapt to the existing `mount/3` shape; the key change is the canonical redirect.)

- [ ] **Step 3: Verify compile**

Run: `mix compile --warnings-as-errors`
Expected: clean (router still references the new name after Task 9; if compiling before Task 9, temporarily expect a router reference error — do Task 9 in the same commit).

- [ ] **Step 4: Commit (with Task 9)**

Commit together with Task 9 so the router and module name stay consistent.

---

### Task 9: Router — `/w/:workspace_id/…` routes + redirect controller

**Files:**
- Create: `lib/perfect_paper_web/controllers/workspace_redirect_controller.ex`
- Modify: `lib/perfect_paper_web/router.ex` (live_session on_mount + routes)
- Test: `test/perfect_paper_web/controllers/workspace_redirect_controller_test.exs`

- [ ] **Step 1: Write the redirect controller**

```elixir
defmodule PerfectPaperWeb.WorkspaceRedirectController do
  @moduledoc """
  Forwards bare workspace-scoped paths (`/reviews`, `/new`) to the user's
  last-used (or Personal) workspace under `/w/:workspace_id/…`. A plain
  controller — no LiveView connection overhead — so old bookmarks and the
  post-login landing keep working.
  """
  use PerfectPaperWeb, :controller

  alias PerfectPaper.Workspaces

  @spec reviews(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reviews(conn, _params), do: redirect(conn, to: "/w/#{ws(conn).id}/reviews")

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, _params), do: redirect(conn, to: "/w/#{ws(conn).id}/new")

  defp ws(conn) do
    user = conn.assigns.current_scope.user

    with id when is_binary(id) <- user.active_workspace_id,
         {:ok, workspace} <- Workspaces.get_workspace(id, user) do
      workspace
    else
      _ -> Workspaces.personal_workspace(user)
    end
  end
end
```

- [ ] **Step 2: Wire routes in `router.ex`**

In the `live_session :require_authenticated_user` block, add `:assign_workspace` to the `on_mount` list, replace the `/new`, `/history`, `/history/:id`, `/workspace/:id` lines with the scoped routes, and keep account-level routes as-is:

```elixir
    live_session :require_authenticated_user,
      on_mount: [
        {PerfectPaperWeb.UserAuth, :require_authenticated},
        {PerfectPaperWeb.UserAuth, :load_locale},
        {PerfectPaperWeb.UserAuth, :assign_workspace}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      # Workspace-scoped surfaces
      live "/w/:workspace_id/new", NewLive, :new
      live "/w/:workspace_id/reviews", HistoryLive.Index, :index
      live "/w/:workspace_id/review/:id", ReadingRoomLive, :show

      # Review detail (legacy non-scoped list detail) stays available
      live "/history/:id", HistoryLive.Show, :show

      # Account-level (global) surfaces
      live "/account", AccountLive, :show
      live "/billing", BillingLive, :index
      live "/earn", EarnLive, :show
      live "/webhooks", WebhooksLive, :index
      live "/orgs/:org_id/sso", SsoLive, :edit
      live "/orgs/:org_id/review-settings", OrgReviewSettingsLive, :edit
      live "/orgs/:org_id/scim", ScimLive, :edit
      live "/orgs/:org_id/billing", OrgBillingLive, :index
    end

    post "/users/update-password", UserSessionController, :update_password

    # Bare → workspace-scoped redirects (old bookmarks, post-login landing)
    get "/new", WorkspaceRedirectController, :new
    get "/reviews", WorkspaceRedirectController, :reviews
    get "/history", WorkspaceRedirectController, :reviews

    # Export keeps its own path (reading room id, not workspace-scoped)
    get "/w/:workspace_id/review/:id/export/:format", ExportController, :show
  end
```

NOTE: the export route's controller reads `:id` (the session id) — `:workspace_id` is ignored there but present for URL consistency. Confirm `ExportController.show/2` still matches on `%{"id" => id, "format" => format}` (extra params are fine).

- [ ] **Step 3: Write the redirect test**

```elixir
defmodule PerfectPaperWeb.WorkspaceRedirectControllerTest do
  use PerfectPaperWeb.ConnCase, async: true
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Workspaces

  test "/reviews redirects to the user's workspace", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    conn = get(log_in_user(conn, user), ~p"/reviews")
    assert redirected_to(conn) == "/w/#{personal.id}/reviews"
  end

  test "/new redirects to the user's workspace", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    conn = get(log_in_user(conn, user), ~p"/new")
    assert redirected_to(conn) == "/w/#{personal.id}/new"
  end
end
```

- [ ] **Step 4: Run + verify**

Run: `mix compile --warnings-as-errors && mix test test/perfect_paper_web/controllers/workspace_redirect_controller_test.exs test/perfect_paper_web/live/reading_room_live_test.exs`
Expected: clean compile; both pass.

- [ ] **Step 5: Commit (Tasks 8 + 9 together)**

```bash
git add lib/perfect_paper_web/live/reading_room_live.ex test/perfect_paper_web/live/reading_room_live_test.exs lib/perfect_paper_web/controllers/workspace_redirect_controller.ex test/perfect_paper_web/controllers/workspace_redirect_controller_test.exs lib/perfect_paper_web/router.ex
git commit -m "feat(workspaces): URL-scoped /w/:workspace_id routes + redirects; rename WorkspaceLive→ReadingRoomLive"
```

---

### Task 10: NewLive — set `workspace_id`, navigate to reading room

**Files:**
- Modify: `lib/perfect_paper_web/live/new_live.ex` (begin_session attrs + redirect)
- Test: `test/perfect_paper_web/live/new_live_test.exs` (append)

- [ ] **Step 1: Write the failing test**

```elixir
  test "a new review lands in the URL's workspace", %{conn: conn} do
    import PerfectPaper.AccountsFixtures
    user = user_fixture()
    {:ok, ws} = PerfectPaper.Workspaces.create_workspace(user, %{name: "Lab"})
    PerfectPaper.CreditsFixtures.grant_fixture(user, 5)

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/w/#{ws.id}/new")

    # Same upload flow as the existing passing tests in this file.
    file =
      file_input(lv, "#upload-form", :manuscript, [
        %{name: "Paper.docx", content: "bytes", type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}
      ])

    render_upload(file, "Paper.docx")
    render_submit(form(lv, "#upload-form"))

    [session] = PerfectPaper.History.list_sessions(PerfectPaper.Authz.load_subject(user))
    assert session.workspace_id == ws.id
  end
```

NOTE: copy the exact `file_input` map shape from a passing test in this file (the existing `:manuscript` upload tests at lines ~36 and ~62) so the upload validations match.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper_web/live/new_live_test.exs`
Expected: FAIL — session has `nil` workspace_id.

- [ ] **Step 3: Implement**

In `new_live.ex` `handle_event("submit", …)`, add `workspace_id` to the `begin_session` attrs and navigate to the scoped reading room:

```elixir
               {:ok, session} <-
                 History.begin_session(%{
                   user_id: user.id,
                   title: title,
                   document_id: document.id,
                   workspace_id: socket.assigns.current_workspace.id
                 }),
```

And change the success redirect:

```elixir
      [{:ok, %History.Session{} = session}] ->
        {:noreply,
         socket
         |> put_flash(:info, "Your review is ready.")
         |> push_navigate(
           to: ~p"/w/#{socket.assigns.current_workspace.id}/review/#{session.id}"
         )}
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/perfect_paper_web/live/new_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/live/new_live.ex test/perfect_paper_web/live/new_live_test.exs
git commit -m "feat(workspaces): new reviews land in the active workspace"
```

---

### Task 11: Reviews list scoped to the active workspace

**Files:**
- Modify: `lib/perfect_paper_web/live/history_live/index.ex` (mount passes workspace_id)
- Test: `test/perfect_paper_web/live/history_live_test.exs` (append)

- [ ] **Step 1: Write the failing test**

```elixir
  test "the reviews list shows only the active workspace's reviews", %{conn: conn} do
    import PerfectPaper.AccountsFixtures
    user = user_fixture()
    {:ok, ws_a} = PerfectPaper.Workspaces.create_workspace(user, %{name: "A"})
    {:ok, ws_b} = PerfectPaper.Workspaces.create_workspace(user, %{name: "B"})
    {:ok, _} = PerfectPaper.History.begin_session(%{user_id: user.id, title: "Alpha review", workspace_id: ws_a.id})
    {:ok, _} = PerfectPaper.History.begin_session(%{user_id: user.id, title: "Beta review", workspace_id: ws_b.id})

    {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/w/#{ws_a.id}/reviews")
    assert html =~ "Alpha review"
    refute html =~ "Beta review"
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper_web/live/history_live_test.exs`
Expected: FAIL — both titles present (no workspace filter yet).

- [ ] **Step 3: Implement**

In `history_live/index.ex` `mount/3`, pass the active workspace to the summary query:

```elixir
       sessions:
         History.list_session_summaries(scope(socket),
           workspace_id: socket.assigns.current_workspace.id
         )
```

(Match the existing `mount` shape; only add the `workspace_id:` option.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/perfect_paper_web/live/history_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/live/history_live/index.ex test/perfect_paper_web/live/history_live_test.exs
git commit -m "feat(workspaces): scope the reviews list to the active workspace"
```

---

### Task 12: `WorkspaceSwitcher` LiveComponent + sidebar wiring + nav rename

**Files:**
- Create: `lib/perfect_paper_web/components/workspace_switcher.ex`
- Modify: `lib/perfect_paper_web/components/app_shell.ex` (brand header → switcher; nav rename + scoped hrefs)
- Test: `test/perfect_paper_web/components/workspace_switcher_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule PerfectPaperWeb.WorkspaceSwitcherTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Workspaces

  test "switcher lists the user's workspaces and links to switch", %{conn: conn} do
    user = user_fixture()
    Workspaces.personal_workspace(user)
    {:ok, lab} = Workspaces.create_workspace(user, %{name: "Lab"})

    {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/w/#{lab.id}/reviews")
    assert html =~ "Personal"
    assert html =~ "Lab"
    assert html =~ "/w/#{lab.id}/reviews"
    assert html =~ "New workspace"
  end

  test "creating a workspace from the switcher navigates into it", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/w/#{personal.id}/reviews")

    lv |> element("#workspace-switcher [data-role=open-create]") |> render_click()

    lv
    |> form("#workspace-switcher form[phx-submit=create_workspace]", %{"name" => "Grant App"})
    |> render_submit()

    created = user |> Workspaces.list_workspaces() |> Enum.find(&(&1.name == "Grant App"))
    assert created
    assert_redirect(lv, "/w/#{created.id}/reviews")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper_web/components/workspace_switcher_test.exs`
Expected: FAIL — switcher not rendered / events unhandled.

- [ ] **Step 3: Write the LiveComponent**

```elixir
defmodule PerfectPaperWeb.WorkspaceSwitcher do
  @moduledoc """
  Sidebar-header workspace switcher: shows the active workspace, drops down to
  switch (navigate to `/w/:id/reviews`) or create a new workspace. Encapsulates
  its own create form + events so the shared app shell needs no per-page wiring.
  """
  use PerfectPaperWeb, :live_component

  alias PerfectPaper.Workspaces

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:creating, fn -> false end)}
  end

  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply, assign(socket, :creating, true)}
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, assign(socket, :creating, false)}
  end

  def handle_event("create_workspace", %{"name" => name}, socket) do
    case Workspaces.create_workspace(socket.assigns.current_user, %{name: name}) do
      {:ok, ws} ->
        {:noreply, push_navigate(socket, to: ~p"/w/#{ws.id}/reviews")}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="workspace-switcher" class="dropdown dropdown-bottom w-full">
      <button
        tabindex="0"
        class="flex w-full items-center gap-2.5 rounded-lg p-1.5 hover:bg-base-200 group-data-[collapsed=true]/shell:justify-center"
        aria-label="Switch workspace"
      >
        <span class="grid size-7 shrink-0 place-items-center rounded-md bg-primary/10 font-sans text-sm font-semibold uppercase text-primary">
          {String.first(@current_workspace.name)}
        </span>
        <span class="group-data-[collapsed=true]/shell:hidden min-w-0 flex-1 truncate text-left font-display text-sm font-semibold">
          {@current_workspace.name}
        </span>
        <.icon
          name="hero-chevron-up-down"
          class="group-data-[collapsed=true]/shell:hidden size-4 shrink-0 text-base-content/40"
        />
      </button>

      <ul
        tabindex="0"
        class="dropdown-content menu z-50 mt-1 w-60 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
      >
        <li :for={ws <- @workspaces}>
          <.link navigate={~p"/w/#{ws.id}/reviews"} class="font-sans text-sm">
            <span class="flex-1 truncate">{ws.name}</span>
            <.icon :if={ws.id == @current_workspace.id} name="hero-check" class="size-4 text-primary" />
          </.link>
        </li>

        <li class="menu-title mt-1 border-t border-base-300 pt-2"></li>

        <li :if={!@creating}>
          <button type="button" data-role="open-create" phx-click="open_create" phx-target={@myself} class="font-sans text-sm">
            <.icon name="hero-plus" class="size-4" /> New workspace
          </button>
        </li>

        <li :if={@creating} class="p-1">
          <form phx-submit="create_workspace" phx-target={@myself} class="flex items-center gap-1.5">
            <input
              name="name"
              autocomplete="off"
              maxlength="120"
              placeholder="Workspace name"
              phx-mounted={JS.focus()}
              class="input input-bordered input-sm w-full font-sans text-sm"
            />
            <button type="submit" class="btn btn-primary btn-sm btn-square" aria-label="Create">
              <.icon name="hero-check" class="size-4" />
            </button>
          </form>
        </li>
      </ul>
    </div>
    """
  end
end
```

- [ ] **Step 4: Render it in the app shell brand header**

In `lib/perfect_paper_web/components/app_shell.ex`, replace the brand block (the `<%!-- brand --%>` `<div>` with the logo + wordmark) with the switcher. The shell must receive `current_workspace`, `workspaces`, and the user — add them as attrs:

Add attrs to `app/1`:

```elixir
  attr :current_workspace, :map, default: nil
  attr :workspaces, :list, default: []
```

Replace the brand `<div>` content with:

```elixir
          <div class="flex h-13 shrink-0 items-center border-b border-base-300 px-2">
            <.live_component
              :if={@current_workspace}
              module={PerfectPaperWeb.WorkspaceSwitcher}
              id="ws-switcher"
              current_user={@current_scope.user}
              current_workspace={@current_workspace}
              workspaces={@workspaces}
            />
            <span
              :if={is_nil(@current_workspace)}
              class="px-1.5 font-display text-lg font-semibold tracking-tight"
            >
              Perfect<span class="text-primary">Paper</span><span class="text-accent">.</span>
            </span>
          </div>
```

Each LiveView that renders `<.app …>` must now pass `current_workspace={@current_workspace} workspaces={@workspaces}` (assigned by the on_mount hook). Update the `<.app>` invocations in the workspace-scoped LiveViews (NewLive, HistoryLive.Index, ReadingRoomLive) and the global ones (AccountLive, BillingLive, EarnLive, WebhooksLive, settings) to forward the two assigns. Since the hook assigns them everywhere, this is a mechanical pass-through.

In `nav_items/1`, rename the History item label to **"Reviews"** and point both it and "New review" at the scoped paths. Because `nav_items/1` has no workspace in scope, change the nav to take the current workspace id — simplest: build hrefs in `app/1` where `@current_workspace` is available, or pass `@current_workspace.id` into `nav_items/1`. Update `nav_items(active: …, workspace_id: id)` to emit `"/w/#{id}/new"` and `"/w/#{id}/reviews"`, and the "History" label becomes "Reviews".

- [ ] **Step 5: Run to verify it passes**

Run: `mix compile --warnings-as-errors && mix test test/perfect_paper_web/components/workspace_switcher_test.exs`
Expected: clean; both pass.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/components/workspace_switcher.ex lib/perfect_paper_web/components/app_shell.ex test/perfect_paper_web/components/workspace_switcher_test.exs
git commit -m "feat(workspaces): sidebar switcher LiveComponent + nav rename History→Reviews"
```

---

### Task 13: Integration — multi-tab isolation + global-page sidebar

**Files:**
- Test: `test/perfect_paper_web/live/workspace_integration_test.exs`

- [ ] **Step 1: Write the tests**

```elixir
defmodule PerfectPaperWeb.WorkspaceIntegrationTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.{Workspaces, History, Authz}

  test "two workspace URLs stay isolated (URL is source of truth)", %{conn: conn} do
    user = user_fixture()
    {:ok, a} = Workspaces.create_workspace(user, %{name: "A"})
    {:ok, b} = Workspaces.create_workspace(user, %{name: "B"})
    {:ok, _} = History.begin_session(%{user_id: user.id, title: "only in A", workspace_id: a.id})

    {:ok, _lv_a, html_a} = live(log_in_user(conn, user), ~p"/w/#{a.id}/reviews")
    {:ok, _lv_b, html_b} = live(log_in_user(conn, user), ~p"/w/#{b.id}/reviews")

    assert html_a =~ "only in A"
    refute html_b =~ "only in A"
  end

  test "a global page (account) renders the switcher with current + list", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)

    {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/account")
    assert html =~ "workspace-switcher"
    assert html =~ personal.name
    assert html =~ "/w/#{personal.id}/reviews"
  end
end
```

- [ ] **Step 2: Run**

Run: `mix test test/perfect_paper_web/live/workspace_integration_test.exs`
Expected: PASS (2 tests). If the account page test fails on a missing assign, confirm `AccountLive` forwards `current_workspace`/`workspaces` into `<.app>` (Task 12 mechanical pass-through).

- [ ] **Step 3: Commit**

```bash
git add test/perfect_paper_web/live/workspace_integration_test.exs
git commit -m "test(workspaces): multi-tab isolation + global-page sidebar"
```

---

### Task 14: Full verification + merge

- [ ] **Step 1: Pre-merge check**

Run: `mix precommit`
Expected: compiles warnings-as-errors, formatted, full suite green. Fix anything red before merging.

- [ ] **Step 2: Manual smoke (optional but recommended)**

Run: `mix phx.server`, log in, confirm: switcher shows Personal; create a workspace → lands in `/w/:id/reviews`; upload a review → it appears only in that workspace; switching workspaces changes the list; `/account` shows the switcher; opening two workspace URLs in two tabs stays isolated.

- [ ] **Step 3: Merge to main**

```bash
git checkout main
git pull --ff-only 2>/dev/null || true
git merge --no-ff feat/workspaces -m "Merge feat/workspaces: v1 workspaces + sidebar switcher"
```

Resolve conflicts if main moved; re-run the targeted suites after merge.

---

## Notes for the implementer

- **Boundary law:** the Workspaces context never touches `history_sessions` directly — review reassignment goes through `History.reassign_reviews/2`. Keep it that way.
- **Architecture law:** `Workspaces` is the only Repo boundary for the `workspaces` table; the web layer calls `Workspaces.*`, never `Repo`.
- **Out of scope (do not build):** workspace sharing/members/roles, a credits-sharing policy, scoping enterprise/group-owned sessions, pandoc export hardening. See the spec's "Risks / follow-ups".
- **Shared checkout:** verify `git branch --show-current` before each commit; `main` may move under you — re-check before/after merge. Use `MIX_TEST_PARTITION` for the shared test DB.
