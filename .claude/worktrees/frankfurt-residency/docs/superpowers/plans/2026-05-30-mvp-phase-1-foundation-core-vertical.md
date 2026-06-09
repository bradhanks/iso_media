# Perfect Paper MVP — Phase 1: Foundation + Core Vertical — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a greenfield Phoenix 1.8 app with local auth and a fully working **History** proofreading vertical (context → REST → LiveView), plus **ApiKeys** + Bearer/token auth and inert realtime scaffolds — compiling, booting, and tested.

**Architecture:** Functional core / imperative shell. Each context module is the only public API and the only `Repo`/IO boundary; schemas carry their own changesets; queries are inline. REST controllers and LiveViews are thin and call only context APIs. See `CLAUDE.md` and `docs/superpowers/specs/2026-05-30-perfect-paper-mvp-design.md`.

**Tech Stack:** Elixir, Phoenix 1.8, LiveView, Ecto + PostgreSQL (`binary_id`), Bandit, bcrypt (via `phx.gen.auth`), Tailwind v4 + daisyUI (Phoenix 1.8 default). REST + LiveView only — no GraphQL/webhooks/async this pass.

> **Workflow reminder (from `CLAUDE.md`):** before starting, cut your own fresh feature branch off `main` (e.g. `git checkout -b phase1-foundation`). Do red→green→refactor. Commit per task. At the end, merge back to `main` and report "committed and merged back to main with no issues." Run only the tests in scope while developing.

---

## File structure (created/modified in this plan)

```
lib/perfect_paper/
  accounts.ex                       # phx.gen.auth (generated)
  accounts/*                        # user.ex, user_token.ex, scope.ex, user_notifier.ex (generated)
  api_keys.ex                       # NEW: context API + Repo boundary + queries
  api_keys/api_key.ex               # NEW: schema + changesets
  history.ex                        # NEW: context API + Repo boundary + queries
  history/session.ex                # NEW: schema + changesets
  history/comment.ex                # NEW: schema + changesets
  history/comment_action.ex         # NEW: schema + changesets
  types.ex                          # NEW: shared :uuid4-ish helpers if needed

lib/perfect_paper_web/
  user_auth.ex                      # generated (browser/session/LiveView auth)
  tokens.ex                         # NEW: Bearer facade (session token OR API key)
  plugs/api_auth.ex                 # NEW: REST auth plug
  controllers/api/history_controller.ex   # NEW
  controllers/api/history_json.ex         # NEW
  controllers/api/fallback_controller.ex  # NEW
  live/history_live/index.ex + index.html.heex   # NEW
  live/history_live/show.ex + show.html.heex     # NEW
  channels/user_socket.ex           # NEW: inert scaffold
  channels/user_channel.ex          # NEW: inert scaffold
  router.ex                         # MODIFY: add /api pipeline + routes + live routes

priv/repo/migrations/               # NEW: api_keys, history_sessions, comments, comment_actions
test/perfect_paper/api_keys_test.exs            # NEW
test/perfect_paper/history_test.exs             # NEW
test/perfect_paper_web/controllers/api/history_controller_test.exs  # NEW
test/perfect_paper_web/live/history_live_test.exs                   # NEW
test/support/fixtures/history_fixtures.ex       # NEW
test/support/fixtures/api_keys_fixtures.ex      # NEW
```

---

## Task 1: Greenfield scaffold + auth

**Files:** whole project (generated). This task is generator-driven, not TDD; verify via the generated tests.

- [ ] **Step 1: Keep the existing Phoenix 1.8 shell; prune the broken domain**

The repo already holds a freshly-generated Phoenix 1.8 app with `phx.gen.auth`,
the asset pipeline (incl. the committed `paper` brand theme + self-hosted fonts),
and the test harness — that **shell is good and must be preserved** (re-running
`phx.new` would clobber the brand CSS). Only the DOMAIN is broken (generic CRUD,
duplicate/corrupted migrations, mis-homed schemas). Remove only that; everything
removed stays in git history.

KEEP: `lib/perfect_paper/accounts*` + `accounts/{user,user_token,scope,user_notifier}.ex`,
`mailer.ex`, `repo.ex`, `application.ex`; all of `lib/perfect_paper_web/` except the
generated CRUD LiveViews; `assets/` (brand theme + fonts); `config/`; `test/support/`,
`accounts_test.exs`, `user_auth_test.exs`, `user_live/*`, accounts fixtures; the
users-auth migration; `docs/`, `CLAUDE.md`, `BRAND.md`, `perfect_paper.tar.gz`.

```bash
cd /Users/bradhanks/perfect_paper
# broken / mis-homed domain contexts + schemas
git rm -r lib/perfect_paper/{billing,chatbot,credits,documents,history,organizations}* 2>/dev/null
git rm lib/perfect_paper/accounts/{marketing_preference,referral}.ex 2>/dev/null
# generated CRUD LiveViews that don't match the product (keep user_live)
git rm -r lib/perfect_paper_web/live/{document_live,organization_live,session_live,subscription_live} 2>/dev/null
# their tests + fixtures
git rm test/perfect_paper/{billing,chatbot,credits,documents,history,organizations}_test.exs 2>/dev/null
git rm test/perfect_paper_web/live/{document_live_test,organization_live_test,session_live_test,subscription_live_test}.exs 2>/dev/null
git rm test/support/fixtures/{billing,chatbot,credits,documents,organizations}_fixtures.ex 2>/dev/null
# every migration EXCEPT the users-auth one
find priv/repo/migrations -name '*.exs' ! -name '*create_users_auth_tables.exs' -delete
```

- [ ] **Step 2: Confirm the shell compiles and auth tests pass**

```bash
mix deps.get
mix ecto.drop && mix ecto.create && mix ecto.migrate
mix compile --warnings-as-errors
mix test test/perfect_paper/accounts_test.exs test/perfect_paper_web/user_auth_test.exs
```

Expected: compiles clean, auth tests green. If `accounts.ex` references removed
schemas (`marketing_preference`/`referral`), trim those functions now — they
return in the Marketing/Referrals contexts in Phase 2.

- [ ] **Step 3: Configure the test database and create it**

Ensure `config/test.exs` points at a reachable Postgres. Then:

```bash
mix ecto.create
mix ecto.migrate
```

- [ ] **Step 4: Run the generated auth test suite to verify the baseline**

Run: `mix test test/perfect_paper/accounts_test.exs test/perfect_paper_web/user_auth_test.exs`
Expected: PASS (all generated auth tests green).

- [ ] **Step 5: Verify it compiles clean and boots**

Run: `mix compile --warnings-as-errors`
Expected: no warnings/errors.
Run: `mix phx.server` (then Ctrl-C). Expected: boots, serves `/`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: greenfield Phoenix 1.8 scaffold + phx.gen.auth"
```

---

## Task 2: History schemas + migrations

**Files:**
- Create: `lib/perfect_paper/history/session.ex`
- Create: `lib/perfect_paper/history/comment.ex`
- Create: `lib/perfect_paper/history/comment_action.ex`
- Create: `priv/repo/migrations/<ts>_create_history.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/<timestamp>_create_history.exs` (use a real
timestamp via `mix ecto.gen.migration create_history` then paste the body):

```elixir
defmodule PerfectPaper.Repo.Migrations.CreateHistory do
  use Ecto.Migration

  def change do
    create table(:history_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :processing_status, :string, null: false, default: "pending"
      add :is_public, :boolean, null: false, default: false
      add :viewed, :boolean, null: false, default: false
      add :overall_feedback, :text
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create index(:history_sessions, [:user_id])

    create table(:comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :original_text, :text
      add :suggestion, :text
      add :explanation, :text
      add :category, :string
      add :status, :string, null: false, default: "open"
      add :position, :integer
      add :session_id, references(:history_sessions, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:session_id])

    create table(:comment_actions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action_type, :string, null: false
      add :session_id, references(:history_sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :comment_id, references(:comments, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create index(:comment_actions, [:comment_id])
    create unique_index(:comment_actions, [:comment_id, :action_type])
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: three tables created, no errors.

- [ ] **Step 3: Write `comment_action.ex` (schema + changeset)**

```elixir
defmodule PerfectPaper.History.CommentAction do
  @moduledoc "An action a writer took on a comment (dismiss/address)."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "comment_actions" do
    field :action_type, Ecto.Enum, values: [:dismiss, :address]
    field :session_id, :binary_id
    field :comment_id, :binary_id
    field :user_id, :binary_id
    timestamps(type: :utc_datetime)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(action, attrs) do
    action
    |> cast(attrs, [:action_type, :session_id, :comment_id, :user_id])
    |> validate_required([:action_type, :session_id, :comment_id, :user_id])
    |> unique_constraint([:comment_id, :action_type])
  end
end
```

- [ ] **Step 4: Write `comment.ex` (schema + changesets)**

```elixir
defmodule PerfectPaper.History.Comment do
  @moduledoc "One piece of proofreading feedback on a session."
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.History.Session

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "comments" do
    field :original_text, :string
    field :suggestion, :string
    field :explanation, :string
    field :category, :string
    field :status, Ecto.Enum, values: [:open, :dismissed, :addressed], default: :open
    field :position, :integer
    belongs_to :session, Session
    timestamps(type: :utc_datetime)
  end

  @spec apply_action_changeset(t(), :dismiss | :address) :: Ecto.Changeset.t()
  def apply_action_changeset(comment, :dismiss), do: change(comment, status: :dismissed)
  def apply_action_changeset(comment, :address), do: change(comment, status: :addressed)

  @spec undo_action_changeset(t(), :dismiss | :address) :: Ecto.Changeset.t()
  def undo_action_changeset(comment, _action_type), do: change(comment, status: :open)
end
```

- [ ] **Step 5: Write `session.ex` (schema + changesets)**

```elixir
defmodule PerfectPaper.History.Session do
  @moduledoc "A proofreading session for a document."
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.History.Comment

  @type t :: %__MODULE__{}

  @statuses [:pending, :converting, :analyzing, :complete, :failed]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "history_sessions" do
    field :title, :string
    field :processing_status, Ecto.Enum, values: @statuses, default: :pending
    field :is_public, :boolean, default: false
    field :viewed, :boolean, default: false
    field :overall_feedback, :string
    field :user_id, :binary_id
    has_many :comments, Comment
    timestamps(type: :utc_datetime)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [:title, :user_id, :processing_status])
    |> validate_required([:user_id])
  end

  @spec complete_changeset(t(), map()) :: Ecto.Changeset.t()
  def complete_changeset(session, attrs) do
    session
    |> cast(attrs, [:overall_feedback, :processing_status])
    |> put_change(:processing_status, :complete)
  end

  @spec flags_changeset(t(), map()) :: Ecto.Changeset.t()
  def flags_changeset(session, attrs) do
    cast(session, attrs, [:is_public, :viewed])
  end
end
```

- [ ] **Step 6: Verify compile**

Run: `mix compile --warnings-as-errors`
Expected: no warnings/errors.

- [ ] **Step 7: Commit**

```bash
git add lib/perfect_paper/history priv/repo/migrations
git commit -m "feat(history): schemas + migration for sessions/comments/actions"
```

---

## Task 3: History context API (TDD)

**Files:**
- Create: `lib/perfect_paper/history.ex`
- Test: `test/perfect_paper/history_test.exs`
- Create: `test/support/fixtures/history_fixtures.ex`

- [ ] **Step 1: Write the fixtures**

```elixir
defmodule PerfectPaper.HistoryFixtures do
  @moduledoc false
  alias PerfectPaper.{History, Repo}
  import PerfectPaper.AccountsFixtures, only: [user_fixture: 0]

  def session_fixture(attrs \\ %{}) do
    user = attrs[:user] || user_fixture()
    {:ok, session} = History.begin_session(%{user_id: user.id, title: "Doc"})
    session
  end

  def comment_fixture(session, attrs \\ %{}) do
    {:ok, comment} =
      %PerfectPaper.History.Comment{session_id: session.id}
      |> Ecto.Changeset.change(Map.merge(%{original_text: "teh", suggestion: "the", status: :open}, attrs))
      |> Repo.insert()

    comment
  end
end
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule PerfectPaper.HistoryTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.History
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  describe "begin_session/1" do
    test "creates a pending session for a user" do
      user = user_fixture()
      assert {:ok, session} = History.begin_session(%{user_id: user.id, title: "Doc"})
      assert session.processing_status == :pending
      assert session.user_id == user.id
    end
  end

  describe "list_sessions/2" do
    test "returns a user's sessions newest first" do
      user = user_fixture()
      {:ok, _a} = History.begin_session(%{user_id: user.id, title: "A"})
      {:ok, b} = History.begin_session(%{user_id: user.id, title: "B"})
      assert [first | _] = History.list_sessions(user.id)
      assert first.id == b.id
    end
  end

  describe "dismiss_comment/3 and undo" do
    test "dismiss sets status and records an action; undo reverts" do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session)

      assert {:ok, %{comment: dismissed}} =
               History.dismiss_comment(session.id, comment.id, by: user.id)
      assert dismissed.status == :dismissed

      assert {:ok, %{comment: reverted}} =
               History.undo_comment_action(session.id, comment.id, user.id, :dismiss)
      assert reverted.status == :open
    end
  end

  describe "set_visibility/2 and mark_viewed/1" do
    test "toggles flags" do
      session = session_fixture()
      assert {:ok, s} = History.set_visibility(session, true)
      assert s.is_public
      assert {:ok, s2} = History.mark_viewed(session)
      assert s2.viewed
    end
  end
end
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: FAIL — `History.begin_session/1` undefined.

- [ ] **Step 4: Implement the context**

```elixir
defmodule PerfectPaper.History do
  @moduledoc """
  Proofreading history — sessions and the actions a writer takes on comments.
  Public API and sole Repo boundary for the History context.
  """
  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.History.{Session, Comment, CommentAction}

  @spec list_sessions(Ecto.UUID.t(), keyword()) :: [Session.t()]
  def list_sessions(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(s in Session,
      where: s.user_id == ^user_id,
      order_by: [desc: s.inserted_at],
      limit: ^limit,
      preload: [:comments]
    )
    |> Repo.all()
  end

  @spec get_session(Ecto.UUID.t()) :: Session.t() | nil
  def get_session(id), do: Repo.get(Session, id) |> Repo.preload(:comments)

  @spec begin_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def begin_session(attrs) do
    %Session{} |> Session.create_changeset(attrs) |> Repo.insert()
  end

  @spec finish_session(Session.t(), map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def finish_session(%Session{} = session, attrs) do
    session |> Session.complete_changeset(attrs) |> Repo.update()
  end

  @spec delete_session(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def delete_session(%Session{} = session), do: Repo.delete(session)

  @spec dismiss_comment(Ecto.UUID.t(), Ecto.UUID.t(), [{:by, Ecto.UUID.t()}]) ::
          {:ok, map()} | {:error, term()}
  def dismiss_comment(session_id, comment_id, by: user_id),
    do: act_on_comment(session_id, comment_id, user_id, :dismiss)

  @spec address_comment(Ecto.UUID.t(), Ecto.UUID.t(), [{:by, Ecto.UUID.t()}]) ::
          {:ok, map()} | {:error, term()}
  def address_comment(session_id, comment_id, by: user_id),
    do: act_on_comment(session_id, comment_id, user_id, :address)

  @spec undo_comment_action(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), :dismiss | :address) ::
          {:ok, map()} | {:error, :not_found}
  def undo_comment_action(session_id, comment_id, user_id, action_type) do
    action =
      Repo.one(
        from a in CommentAction,
          where:
            a.session_id == ^session_id and a.comment_id == ^comment_id and
              a.user_id == ^user_id and a.action_type == ^action_type
      )

    comment = Repo.get(Comment, comment_id)

    if action && comment do
      Ecto.Multi.new()
      |> Ecto.Multi.delete(:action, action)
      |> Ecto.Multi.update(:comment, Comment.undo_action_changeset(comment, action_type))
      |> Repo.transaction()
    else
      {:error, :not_found}
    end
  end

  @spec set_visibility(Session.t(), boolean()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def set_visibility(%Session{} = session, is_public) when is_boolean(is_public),
    do: session |> Session.flags_changeset(%{is_public: is_public}) |> Repo.update()

  @spec mark_viewed(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def mark_viewed(%Session{} = session),
    do: session |> Session.flags_changeset(%{viewed: true}) |> Repo.update()

  # Reused scope: a comment within a session. Extracted because both action
  # paths need it.
  defp act_on_comment(session_id, comment_id, user_id, action_type) do
    case Repo.one(from c in Comment, where: c.id == ^comment_id and c.session_id == ^session_id) do
      nil ->
        {:error, :comment_not_found}

      comment ->
        attrs = %{
          session_id: session_id,
          comment_id: comment_id,
          user_id: user_id,
          action_type: action_type
        }

        Ecto.Multi.new()
        |> Ecto.Multi.insert(:action, CommentAction.create_changeset(%CommentAction{}, attrs))
        |> Ecto.Multi.update(:comment, Comment.apply_action_changeset(comment, action_type))
        |> Repo.transaction()
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: PASS (all 4 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/history.ex test/perfect_paper/history_test.exs test/support/fixtures/history_fixtures.ex
git commit -m "feat(history): context API with TDD coverage"
```

---

## Task 4: ApiKeys context (TDD)

**Files:**
- Create: `lib/perfect_paper/api_keys/api_key.ex`, `lib/perfect_paper/api_keys.ex`
- Create: `priv/repo/migrations/<ts>_create_api_keys.exs`
- Test: `test/perfect_paper/api_keys_test.exs`
- Create: `test/support/fixtures/api_keys_fixtures.ex`

- [ ] **Step 1: Write + run the migration**

`mix ecto.gen.migration create_api_keys`, then body:

```elixir
defmodule PerfectPaper.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :prefix, :string, null: false
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_keys, [:token_hash])
    create index(:api_keys, [:user_id])
  end
end
```

Run: `mix ecto.migrate` — Expected: table created.

- [ ] **Step 2: Write the schema**

```elixir
defmodule PerfectPaper.ApiKeys.ApiKey do
  @moduledoc "A hashed API key belonging to a user."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :name, :string
    field :prefix, :string
    field :token_hash, :binary
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :user_id, :binary_id
    timestamps(type: :utc_datetime)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :prefix, :token_hash, :user_id])
    |> validate_required([:prefix, :token_hash, :user_id])
    |> unique_constraint(:token_hash)
  end
end
```

- [ ] **Step 3: Write the fixtures + failing test**

`test/support/fixtures/api_keys_fixtures.ex`:

```elixir
defmodule PerfectPaper.ApiKeysFixtures do
  @moduledoc false
  alias PerfectPaper.ApiKeys
  import PerfectPaper.AccountsFixtures, only: [user_fixture: 0]

  def api_key_fixture(attrs \\ %{}) do
    user = attrs[:user] || user_fixture()
    {:ok, raw, key} = ApiKeys.generate(user, attrs[:name] || "default")
    %{raw: raw, key: key, user: user}
  end
end
```

`test/perfect_paper/api_keys_test.exs`:

```elixir
defmodule PerfectPaper.ApiKeysTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.ApiKeys
  import PerfectPaper.AccountsFixtures

  test "generate/2 returns a raw token that verify/1 accepts" do
    user = user_fixture()
    assert {:ok, raw, key} = ApiKeys.generate(user, "ci")
    assert is_binary(raw)
    assert key.user_id == user.id
    assert {:ok, verified} = ApiKeys.verify(raw)
    assert verified.id == key.id
  end

  test "verify/1 rejects unknown and revoked keys" do
    user = user_fixture()
    {:ok, raw, key} = ApiKeys.generate(user, "ci")
    assert ApiKeys.verify("pp_nope") == {:error, :invalid}
    {:ok, _} = ApiKeys.revoke_key(key)
    assert ApiKeys.verify(raw) == {:error, :invalid}
  end

  test "list_keys/1 returns only the user's active keys" do
    user = user_fixture()
    {:ok, _raw, _key} = ApiKeys.generate(user, "a")
    assert length(ApiKeys.list_keys(user.id)) == 1
  end
end
```

- [ ] **Step 4: Run to confirm failure**

Run: `mix test test/perfect_paper/api_keys_test.exs`
Expected: FAIL — `ApiKeys.generate/2` undefined.

- [ ] **Step 5: Implement the context**

```elixir
defmodule PerfectPaper.ApiKeys do
  @moduledoc """
  Issue, list, revoke, and verify API keys. Public API + sole Repo boundary.
  Raw tokens are shown once at creation; only their SHA-256 hash is stored.
  """
  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.ApiKeys.ApiKey

  @prefix "pp_"

  @spec generate(struct(), String.t()) :: {:ok, String.t(), ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def generate(user, name) do
    secret = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    raw = @prefix <> secret

    attrs = %{
      name: name,
      prefix: @prefix,
      token_hash: hash(raw),
      user_id: user.id
    }

    case %ApiKey{} |> ApiKey.create_changeset(attrs) |> Repo.insert() do
      {:ok, key} -> {:ok, raw, key}
      {:error, cs} -> {:error, cs}
    end
  end

  @spec list_keys(Ecto.UUID.t()) :: [ApiKey.t()]
  def list_keys(user_id) do
    Repo.all(from k in ApiKey, where: k.user_id == ^user_id and is_nil(k.revoked_at))
  end

  @spec revoke_key(ApiKey.t()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def revoke_key(%ApiKey{} = key) do
    key
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @spec verify(String.t()) :: {:ok, ApiKey.t()} | {:error, :invalid}
  def verify(raw) when is_binary(raw) do
    case Repo.one(from k in ApiKey, where: k.token_hash == ^hash(raw) and is_nil(k.revoked_at)) do
      nil -> {:error, :invalid}
      key -> {:ok, key}
    end
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)
end
```

- [ ] **Step 6: Run to verify pass**

Run: `mix test test/perfect_paper/api_keys_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/perfect_paper/api_keys* priv/repo/migrations test/perfect_paper/api_keys_test.exs test/support/fixtures/api_keys_fixtures.ex
git commit -m "feat(api_keys): issue/list/revoke/verify with TDD coverage"
```

---

## Task 5: Bearer token facade + ApiAuth plug (TDD)

**Files:**
- Create: `lib/perfect_paper_web/tokens.ex`
- Create: `lib/perfect_paper_web/plugs/api_auth.ex`
- Test: `test/perfect_paper_web/plugs/api_auth_test.exs`

- [ ] **Step 1: Write the failing plug test**

```elixir
defmodule PerfectPaperWeb.Plugs.ApiAuthTest do
  use PerfectPaperWeb.ConnCase, async: true

  alias PerfectPaperWeb.Plugs.ApiAuth
  import PerfectPaper.AccountsFixtures

  test "assigns current_user for a valid API key", %{conn: conn} do
    user = user_fixture()
    {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(user, "ci")

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
      |> ApiAuth.call(ApiAuth.init([]))

    assert conn.assigns.current_user.id == user.id
    refute conn.halted
  end

  test "halts with 401 when missing/invalid", %{conn: conn} do
    conn = conn |> ApiAuth.call(ApiAuth.init([]))
    assert conn.halted
    assert conn.status == 401
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `mix test test/perfect_paper_web/plugs/api_auth_test.exs`
Expected: FAIL — module not available.

- [ ] **Step 3: Implement the token facade**

```elixir
defmodule PerfectPaperWeb.Tokens do
  @moduledoc """
  Resolves an `Authorization: Bearer <value>` into a user. Tries the value as a
  local session token first, then as an API key. This is the header/API side of
  auth; `user_auth.ex` owns the cookie/LiveView side.
  """
  alias PerfectPaper.{Accounts, ApiKeys}

  @spec user_for_bearer(String.t()) :: {:ok, struct()} | {:error, :invalid}
  def user_for_bearer(value) when is_binary(value) do
    with nil <- user_from_session_token(value),
         {:error, :invalid} <- user_from_api_key(value) do
      {:error, :invalid}
    else
      %{} = user -> {:ok, user}
      {:ok, user} -> {:ok, user}
    end
  end

  defp user_from_session_token(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> Accounts.get_user_by_session_token(decoded)
      :error -> nil
    end
  end

  defp user_from_api_key(value) do
    case ApiKeys.verify(value) do
      {:ok, key} -> {:ok, Accounts.get_user!(key.user_id)}
      {:error, :invalid} -> {:error, :invalid}
    end
  end
end
```

> NOTE: confirm the exact `Accounts.get_user_by_session_token/1` name from the
> generated `accounts.ex`; Phoenix 1.8 generates it. Adjust if the generator
> used a different arity/name.

- [ ] **Step 4: Implement the plug**

```elixir
defmodule PerfectPaperWeb.Plugs.ApiAuth do
  @moduledoc "Authenticates REST requests via Bearer token (session token or API key)."
  import Plug.Conn

  alias PerfectPaperWeb.Tokens

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> value] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Tokens.user_for_bearer(value) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end
end
```

- [ ] **Step 5: Run to verify pass**

Run: `mix test test/perfect_paper_web/plugs/api_auth_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/tokens.ex lib/perfect_paper_web/plugs/api_auth.ex test/perfect_paper_web/plugs/api_auth_test.exs
git commit -m "feat(web): Bearer token facade + ApiAuth plug with TDD coverage"
```

---

## Task 6: History REST controller + FallbackController (TDD)

**Files:**
- Create: `lib/perfect_paper_web/controllers/api/fallback_controller.ex`
- Create: `lib/perfect_paper_web/controllers/api/history_controller.ex`
- Create: `lib/perfect_paper_web/controllers/api/history_json.ex`
- Modify: `lib/perfect_paper_web/router.ex`
- Test: `test/perfect_paper_web/controllers/api/history_controller_test.exs`

- [ ] **Step 1: Add the API pipeline + routes to the router**

In `lib/perfect_paper_web/router.ex`, add:

```elixir
  pipeline :api do
    plug :accepts, ["json"]
    plug PerfectPaperWeb.Plugs.ApiAuth
  end

  scope "/api", PerfectPaperWeb.Api, as: :api do
    pipe_through :api

    get "/history", HistoryController, :index
    get "/history/:id", HistoryController, :show
    delete "/history/:id", HistoryController, :delete
    patch "/history/:session_id/comments/:comment_id/dismiss", HistoryController, :dismiss
    patch "/history/:session_id/comments/:comment_id/address", HistoryController, :address
    patch "/history/:id/visibility", HistoryController, :set_visibility
    post "/history/:id/mark-viewed", HistoryController, :mark_viewed
  end
```

- [ ] **Step 2: Write the failing controller test**

```elixir
defmodule PerfectPaperWeb.Api.HistoryControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(user, "ci")
    conn = put_req_header(conn, "authorization", "Bearer " <> raw)
    {:ok, conn: put_req_header(conn, "accept", "application/json"), user: user}
  end

  test "GET /api/history lists the user's sessions", %{conn: conn, user: user} do
    _s = session_fixture(user: user)
    resp = conn |> get(~p"/api/history") |> json_response(200)
    assert is_list(resp["data"])
    assert length(resp["data"]) == 1
  end

  test "PATCH dismiss marks a comment dismissed", %{conn: conn, user: user} do
    session = session_fixture(user: user)
    comment = comment_fixture(session)
    resp =
      conn
      |> patch(~p"/api/history/#{session.id}/comments/#{comment.id}/dismiss")
      |> json_response(200)

    assert resp["data"]["status"] == "dismissed"
  end

  test "401 without a token", %{} do
    assert build_conn() |> get(~p"/api/history") |> json_response(401)
  end
end
```

- [ ] **Step 3: Run to confirm failure**

Run: `mix test test/perfect_paper_web/controllers/api/history_controller_test.exs`
Expected: FAIL — controller/route missing.

- [ ] **Step 4: Implement FallbackController**

```elixir
defmodule PerfectPaperWeb.Api.FallbackController do
  @moduledoc "Uniform JSON error envelope for the REST API."
  use PerfectPaperWeb, :controller

  def call(conn, {:error, :not_found}), do: send_error(conn, 404, "not found")
  def call(conn, {:error, :comment_not_found}), do: send_error(conn, 404, "comment not found")
  def call(conn, {:error, %Ecto.Changeset{} = cs}) do
    send_error(conn, 422, Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end))
  end
  def call(conn, {:error, _}), do: send_error(conn, 400, "bad request")

  defp send_error(conn, status, detail) do
    conn |> put_status(status) |> json(%{error: detail})
  end
end
```

- [ ] **Step 5: Implement the JSON view**

```elixir
defmodule PerfectPaperWeb.Api.HistoryJSON do
  alias PerfectPaper.History.{Session, Comment}

  def index(%{sessions: sessions}), do: %{data: Enum.map(sessions, &session/1)}
  def show(%{session: session}), do: %{data: session(session)}
  def comment(%{comment: comment}), do: %{data: comment_map(comment)}

  defp session(%Session{} = s) do
    %{
      id: s.id,
      title: s.title,
      processing_status: s.processing_status,
      is_public: s.is_public,
      viewed: s.viewed,
      comments: for(c <- (s.comments || []), do: comment_map(c))
    }
  end

  defp comment_map(%Comment{} = c) do
    %{id: c.id, original_text: c.original_text, suggestion: c.suggestion, status: c.status}
  end
end
```

- [ ] **Step 6: Implement the controller**

```elixir
defmodule PerfectPaperWeb.Api.HistoryController do
  use PerfectPaperWeb, :controller

  alias PerfectPaper.History

  action_fallback PerfectPaperWeb.Api.FallbackController

  def index(conn, _params) do
    sessions = History.list_sessions(conn.assigns.current_user.id)
    render(conn, :index, sessions: sessions)
  end

  def show(conn, %{"id" => id}) do
    case History.get_session(id) do
      nil -> {:error, :not_found}
      session -> render(conn, :show, session: session)
    end
  end

  def delete(conn, %{"id" => id}) do
    with session when not is_nil(session) <- History.get_session(id),
         {:ok, _} <- History.delete_session(session) do
      send_resp(conn, 204, "")
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  def dismiss(conn, %{"session_id" => sid, "comment_id" => cid}) do
    with {:ok, %{comment: comment}} <-
           History.dismiss_comment(sid, cid, by: conn.assigns.current_user.id) do
      render(conn, :comment, comment: comment)
    end
  end

  def address(conn, %{"session_id" => sid, "comment_id" => cid}) do
    with {:ok, %{comment: comment}} <-
           History.address_comment(sid, cid, by: conn.assigns.current_user.id) do
      render(conn, :comment, comment: comment)
    end
  end

  def set_visibility(conn, %{"id" => id} = params) do
    with session when not is_nil(session) <- History.get_session(id),
         {:ok, updated} <- History.set_visibility(session, !!params["is_public"]) do
      render(conn, :show, session: updated)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  def mark_viewed(conn, %{"id" => id}) do
    with session when not is_nil(session) <- History.get_session(id),
         {:ok, updated} <- History.mark_viewed(session) do
      render(conn, :show, session: updated)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end
end
```

- [ ] **Step 7: Run to verify pass**

Run: `mix test test/perfect_paper_web/controllers/api/history_controller_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 8: Commit**

```bash
git add lib/perfect_paper_web/controllers/api lib/perfect_paper_web/router.ex test/perfect_paper_web/controllers/api
git commit -m "feat(api): History REST controller + fallback with TDD coverage"
```

---

## Task 7: HistoryLive index + show (TDD smoke)

**Files:**
- Create: `lib/perfect_paper_web/live/history_live/index.ex` + `index.html.heex`
- Create: `lib/perfect_paper_web/live/history_live/show.ex` + `show.html.heex`
- Modify: `lib/perfect_paper_web/router.ex` (authenticated live routes)
- Test: `test/perfect_paper_web/live/history_live_test.exs`

- [ ] **Step 1: Add authenticated live routes**

Inside the existing `live_session :require_authenticated_user` scope in
`router.ex`, add:

```elixir
      live "/history", HistoryLive.Index, :index
      live "/history/:id", HistoryLive.Show, :show
```

- [ ] **Step 2: Write the failing LiveView test**

```elixir
defmodule PerfectPaperWeb.HistoryLiveTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  test "index lists the user's sessions", %{conn: conn} do
    user = user_fixture()
    session = session_fixture(user: user)
    conn = log_in_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/history")
    assert html =~ session.title
  end

  test "show can dismiss a comment", %{conn: conn} do
    user = user_fixture()
    session = session_fixture(user: user)
    comment = comment_fixture(session)
    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/history/#{session.id}")
    html = lv |> element("button[phx-value-id='#{comment.id}']", "Dismiss") |> render_click()
    assert html =~ "dismissed"
  end
end
```

- [ ] **Step 3: Run to confirm failure**

Run: `mix test test/perfect_paper_web/live/history_live_test.exs`
Expected: FAIL — LiveViews missing.

- [ ] **Step 4: Implement `HistoryLive.Index`**

`index.ex`:

```elixir
defmodule PerfectPaperWeb.HistoryLive.Index do
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.History

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    {:ok, assign(socket, sessions: History.list_sessions(user.id))}
  end
end
```

> NOTE: Phoenix 1.8 puts the signed-in user at `socket.assigns.current_scope.user`.
> Confirm against the generated `user_auth.ex` `on_mount` and adjust if needed.

`index.html.heex`:

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <h1 class="text-2xl font-bold mb-4">Proofreading history</h1>
  <ul class="space-y-2">
    <li :for={session <- @sessions} class="card bg-base-200 p-4">
      <.link navigate={~p"/history/#{session.id}"} class="link">{session.title}</.link>
    </li>
  </ul>
</Layouts.app>
```

- [ ] **Step 5: Implement `HistoryLive.Show`**

`show.ex`:

```elixir
defmodule PerfectPaperWeb.HistoryLive.Show do
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.History

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign(socket, session: History.get_session(id))}
  end

  @impl true
  def handle_event("dismiss", %{"id" => comment_id}, socket) do
    user = socket.assigns.current_scope.user
    session = socket.assigns.session
    {:ok, _} = History.dismiss_comment(session.id, comment_id, by: user.id)
    {:noreply, assign(socket, session: History.get_session(session.id))}
  end
end
```

`show.html.heex`:

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <h1 class="text-2xl font-bold mb-4">{@session.title}</h1>
  <div :for={comment <- @session.comments} class="card bg-base-200 p-4 mb-2">
    <p class="line-through opacity-60">{comment.original_text}</p>
    <p class="font-medium">{comment.suggestion}</p>
    <span class="badge">{comment.status}</span>
    <button
      :if={comment.status == :open}
      class="btn btn-sm btn-outline mt-2"
      phx-click="dismiss"
      phx-value-id={comment.id}
    >
      Dismiss
    </button>
  </div>
</Layouts.app>
```

- [ ] **Step 6: Run to verify pass**

Run: `mix test test/perfect_paper_web/live/history_live_test.exs`
Expected: PASS (2 tests). Fix any assigns-name mismatches (`current_scope`) until green — do not move on with a red test.

- [ ] **Step 7: Commit**

```bash
git add lib/perfect_paper_web/live/history_live lib/perfect_paper_web/router.ex test/perfect_paper_web/live/history_live_test.exs
git commit -m "feat(live): HistoryLive index + show with TDD smoke coverage"
```

---

## Task 8: Inert realtime scaffolds

**Files:**
- Create: `lib/perfect_paper_web/channels/user_socket.ex`
- Create: `lib/perfect_paper_web/channels/user_channel.ex`
- Modify: `lib/perfect_paper_web/endpoint.ex`

- [ ] **Step 1: Write the socket (no channels wired)**

```elixir
defmodule PerfectPaperWeb.UserSocket do
  @moduledoc "Inert scaffold for future realtime/collab. No channels wired yet."
  use Phoenix.Socket

  # channel "session:*", PerfectPaperWeb.UserChannel  # enabled in a later pass

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
```

- [ ] **Step 2: Write the inert channel**

```elixir
defmodule PerfectPaperWeb.UserChannel do
  @moduledoc "Inert scaffold for future realtime/collab."
  use Phoenix.Channel

  @impl true
  def join("session:" <> _id, _payload, socket), do: {:ok, socket}
end
```

- [ ] **Step 3: Register the socket in the endpoint**

In `lib/perfect_paper_web/endpoint.ex`, add near the top of the module:

```elixir
  socket "/socket", PerfectPaperWeb.UserSocket, websocket: true, longpoll: false
```

- [ ] **Step 4: Verify compile + boot**

Run: `mix compile --warnings-as-errors`
Expected: clean.
Run: `mix phx.server` then Ctrl-C. Expected: boots without errors.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/channels lib/perfect_paper_web/endpoint.ex
git commit -m "feat(web): inert user_socket + user_channel scaffolds"
```

---

## Task 9: Final verification + merge

- [ ] **Step 1: Run the full scoped suite once (pre-merge check)**

Run: `mix test`
Expected: all green. Any failure is yours to fix before merging — no exceptions.

- [ ] **Step 2: Warnings-as-errors gate**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Format**

Run: `mix format`

- [ ] **Step 4: Merge back to main**

```bash
git checkout main
git merge --no-ff phase1-foundation -m "Merge: MVP Phase 1 — foundation + core vertical"
git branch -d phase1-foundation
```

Report: "committed and merged back to main with no issues."

---

## Self-review notes (author)

- **Spec coverage:** foundation (greenfield 1.8 + auth) → Task 1; History context + REST + LiveView (core vertical) → Tasks 2/3/6/7; ApiKeys + Bearer/token auth → Tasks 4/5; realtime stubs → Task 8; DoD (compile/boot/tested) → Task 9. Credits read + the other "modeled" contexts are **deferred to Phase 2** by design.
- **Known executor watch-points (verify against generated code, fix if off):**
  1. `Accounts.get_user_by_session_token/1` name/arity (Task 5) — Phoenix 1.8 generates it; confirm.
  2. Signed-in user assign is `current_scope.user` (Tasks 7) — confirm against generated `user_auth.ex`; the REST side uses `assigns.current_user` set by our own plug.
  3. `Layouts.app` attrs (`current_scope`) match the generated layout.
  4. `log_in_user/2` test helper exists in the generated `ConnCase`.
- **No GraphQL/webhooks/async** anywhere in this plan, per scope.
