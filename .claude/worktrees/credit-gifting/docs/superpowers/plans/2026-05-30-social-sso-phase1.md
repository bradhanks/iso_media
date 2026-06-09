# Social SSO — Phase 1 (Framework + Google + GitHub) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one-click social sign-in with a provider-agnostic framework and Google + GitHub wired as the first two providers, alongside the existing magic-link/password flows.

**Architecture:** OAuth runs through a plain Phoenix controller (full-page redirect, not LiveView). Provider HTTP sits behind an `Accounts.OAuth` behaviour with an Assent-backed adapter (default) and a Stub adapter (tests). All sign-in/linking logic lives in the `Accounts` context, using `Ecto.Multi` for the create-user-plus-identity write. A new `user_identities` table links providers to users; auto-linking happens only on a verified provider email.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView, Assent (OAuth), Req (HTTP), Ecto/Postgres (`binary_id`), ExUnit.

**Spec:** `docs/superpowers/specs/2026-05-30-social-sso-design.md`

**Branch/dir:** Work in the running checkout `/Users/bradhanks/perfect_paper` on branch `feature/magic-link-auth-ux` (this is where the dev server runs, so the buttons appear live). Commit only the files each task lists; leave unrelated WIP untouched.

---

## File Structure

- `lib/perfect_paper/accounts/oauth.ex` — behaviour (callbacks + `identity` type).
- `lib/perfect_paper/accounts/oauth/assent.ex` — default adapter; the only module that references Assent / provider specifics; normalises claims.
- `lib/perfect_paper/accounts/oauth/stub.ex` — test adapter driven by the process dictionary.
- `lib/perfect_paper/accounts/user_identity.ex` — schema + pure changeset.
- `priv/repo/migrations/20260530140000_create_user_identities.exs` — table.
- `lib/perfect_paper/accounts.ex` — add `sso_authorize_url/1`, `sso_sign_in/3`, `configured_providers/0` + linking logic.
- `lib/perfect_paper/accounts/user.ex` — `has_many :identities`.
- `lib/perfect_paper_web/controllers/oauth_controller.ex` — request + callback.
- `lib/perfect_paper_web/components/auth_providers.ex` — social-button row component + inline brand SVGs.
- `lib/perfect_paper_web/router.ex` — `/auth/:provider` routes.
- `config/config.exs`, `config/test.exs`, `config/runtime.exs` — adapter selection + provider env.
- Tests: `test/perfect_paper/accounts_sso_test.exs`, `test/perfect_paper/accounts/user_identity_test.exs`, `test/perfect_paper_web/controllers/oauth_controller_test.exs`.
- `docs/oauth-setup.md` — Google + GitHub provisioning checklist.

---

## Task 1: Add Assent + configure the adapter

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add the dependency**

In `mix.exs` deps, add (Req is already present and is Assent's HTTP client):

```elixir
{:assent, "~> 0.2"},
```

- [ ] **Step 2: Fetch it**

Run: `mix deps.get`
Expected: `assent` resolves and installs, no errors.

- [ ] **Step 3: Select the default adapter (prod/dev) and the stub (test)**

In `config/config.exs`, add near the other `config :perfect_paper` lines:

```elixir
# OAuth / social sign-in. The adapter is the only seam that talks to providers.
config :perfect_paper, :oauth_adapter, PerfectPaper.Accounts.OAuth.Assent
config :perfect_paper, :oauth_providers, %{}
```

In `config/test.exs`, add:

```elixir
config :perfect_paper, :oauth_adapter, PerfectPaper.Accounts.OAuth.Stub
```

- [ ] **Step 4: Verify compile**

Run: `mix compile`
Expected: compiles (the referenced modules don't exist yet but config values are just atoms — no compile error).

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock config/config.exs config/test.exs
git commit -m "feat(sso): add Assent dependency and oauth adapter config"
```

---

## Task 2: UserIdentity schema + migration

**Files:**
- Create: `lib/perfect_paper/accounts/user_identity.ex`
- Create: `priv/repo/migrations/20260530140000_create_user_identities.exs`
- Test: `test/perfect_paper/accounts/user_identity_test.exs`

- [ ] **Step 1: Write the failing changeset test**

Create `test/perfect_paper/accounts/user_identity_test.exs`:

```elixir
defmodule PerfectPaper.Accounts.UserIdentityTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Accounts.UserIdentity

  @valid %{
    user_id: Ecto.UUID.generate(),
    provider: "google",
    provider_uid: "1234567890",
    provider_email: "person@example.com"
  }

  test "valid attributes produce a valid changeset" do
    assert UserIdentity.changeset(%UserIdentity{}, @valid).valid?
  end

  test "requires user_id, provider, and provider_uid" do
    changeset = UserIdentity.changeset(%UserIdentity{}, %{})
    errors = errors_on(changeset)
    assert errors[:user_id]
    assert errors[:provider]
    assert errors[:provider_uid]
  end

  test "rejects an unknown provider" do
    changeset = UserIdentity.changeset(%UserIdentity{}, %{@valid | provider: "myspace"})
    assert errors_on(changeset)[:provider]
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/perfect_paper/accounts/user_identity_test.exs`
Expected: FAIL — `UserIdentity` is undefined.

- [ ] **Step 3: Create the schema + changeset**

Create `lib/perfect_paper/accounts/user_identity.ex`:

```elixir
defmodule PerfectPaper.Accounts.UserIdentity do
  @moduledoc """
  A link between a `User` and an external identity provider (Google, GitHub,
  etc.). A user may have many identities; each `(provider, provider_uid)` pair
  is globally unique.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(google microsoft orcid github apple)

  schema "user_identities" do
    field :provider, :string
    field :provider_uid, :string
    field :provider_email, :string

    belongs_to :user, PerfectPaper.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Known provider keys, in display order."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @doc "Validates an identity link before insert."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:user_id, :provider, :provider_uid, :provider_email])
    |> validate_required([:user_id, :provider, :provider_uid])
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint([:provider, :provider_uid],
      name: :user_identities_provider_provider_uid_index
    )
  end

  @type t :: %__MODULE__{}
end
```

- [ ] **Step 4: Create the migration**

Create `priv/repo/migrations/20260530140000_create_user_identities.exs`:

```elixir
defmodule PerfectPaper.Repo.Migrations.CreateUserIdentities do
  use Ecto.Migration

  def change do
    create table(:user_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :provider_uid, :string, null: false
      add :provider_email, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_identities, [:provider, :provider_uid])
    create index(:user_identities, [:user_id])
  end
end
```

- [ ] **Step 5: Migrate the test DB and run the test**

Run: `mix ecto.migrate` then `mix test test/perfect_paper/accounts/user_identity_test.exs`
Expected: migration runs; tests PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/accounts/user_identity.ex priv/repo/migrations/20260530140000_create_user_identities.exs test/perfect_paper/accounts/user_identity_test.exs
git commit -m "feat(sso): add user_identities table + UserIdentity schema"
```

---

## Task 3: Associate identities on User

**Files:**
- Modify: `lib/perfect_paper/accounts/user.ex` (schema block)

- [ ] **Step 1: Add the association**

In `lib/perfect_paper/accounts/user.ex`, inside the `schema "users" do ... end` block, add after the `field`s and before `timestamps(...)`:

```elixir
    has_many :identities, PerfectPaper.Accounts.UserIdentity
```

- [ ] **Step 2: Verify compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/perfect_paper/accounts/user.ex
git commit -m "feat(sso): User has_many identities"
```

---

## Task 4: OAuth behaviour + Stub adapter

**Files:**
- Create: `lib/perfect_paper/accounts/oauth.ex`
- Create: `lib/perfect_paper/accounts/oauth/stub.ex`

- [ ] **Step 1: Create the behaviour**

Create `lib/perfect_paper/accounts/oauth.ex`:

```elixir
defmodule PerfectPaper.Accounts.OAuth do
  @moduledoc """
  Anti-corruption boundary for social sign-in. The adapter is the only module
  that talks to a provider; it returns a normalised, atom-keyed `identity` map
  so the `Accounts` context never sees provider/Assent specifics.

  Select the adapter with `config :perfect_paper, :oauth_adapter, Module`.
  """

  @type provider :: String.t()
  @type session_params :: map()
  @type identity :: %{
          provider: String.t(),
          uid: String.t(),
          email: String.t() | nil,
          email_verified: boolean(),
          name: String.t() | nil
        }

  @callback authorize_url(provider) ::
              {:ok, %{url: String.t(), session_params: session_params}}
              | {:error, term()}

  @callback callback(provider, params :: map(), session_params) ::
              {:ok, identity} | {:error, term()}

  @doc "The configured adapter module."
  @spec adapter() :: module()
  def adapter, do: Application.fetch_env!(:perfect_paper, :oauth_adapter)
end
```

- [ ] **Step 2: Create the Stub adapter**

Create `lib/perfect_paper/accounts/oauth/stub.ex`:

```elixir
defmodule PerfectPaper.Accounts.OAuth.Stub do
  @moduledoc """
  Test adapter. Tests seed the next `callback/3` result with `put_identity/1`
  (or `put_error/1`); `authorize_url/1` returns a fixed fake URL.
  """
  @behaviour PerfectPaper.Accounts.OAuth

  @key {__MODULE__, :identity}

  @doc "Seed the identity (or {:error, reason}) the next callback/3 returns."
  def put_identity(identity), do: Process.put(@key, {:ok, identity})
  def put_error(reason), do: Process.put(@key, {:error, reason})

  @impl true
  def authorize_url(provider) do
    {:ok, %{url: "https://example.test/auth/#{provider}", session_params: %{state: "stub-state"}}}
  end

  @impl true
  def callback(_provider, _params, _session_params) do
    Process.get(@key, {:error, :no_stub_identity})
  end
end
```

- [ ] **Step 3: Verify compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add lib/perfect_paper/accounts/oauth.ex lib/perfect_paper/accounts/oauth/stub.ex
git commit -m "feat(sso): OAuth behaviour + Stub adapter"
```

---

## Task 5: Accounts sign-in + linking logic (all branches)

**Files:**
- Modify: `lib/perfect_paper/accounts.ex`
- Test: `test/perfect_paper/accounts_sso_test.exs`

**Behaviour:** `sso_sign_in/3` resolves the adapter's identity into a user via the five spec rules. `sso_authorize_url/1` delegates to the adapter. `configured_providers/0` lists configured providers in display order.

- [ ] **Step 1: Write the failing tests**

Create `test/perfect_paper/accounts_sso_test.exs`:

```elixir
defmodule PerfectPaper.AccountsSsoTest do
  use PerfectPaper.DataCase, async: true

  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Accounts
  alias PerfectPaper.Accounts.{User, UserIdentity}
  alias PerfectPaper.Accounts.OAuth.Stub
  alias PerfectPaper.Repo

  defp identity(attrs) do
    Map.merge(
      %{provider: "google", uid: "uid-1", email: nil, email_verified: false, name: "A"},
      Map.new(attrs)
    )
  end

  describe "sso_sign_in/3" do
    test "known identity logs the existing user in" do
      user = user_fixture()
      {:ok, _} = Repo.insert(UserIdentity.changeset(%UserIdentity{}, %{
        user_id: user.id, provider: "google", provider_uid: "uid-1"
      }))

      Stub.put_identity(identity(uid: "uid-1", email: "whatever@example.com"))
      assert {:ok, %User{id: id}} = Accounts.sso_sign_in("google", %{}, %{})
      assert id == user.id
    end

    test "verified email matching an existing user auto-links" do
      user = user_fixture()
      Stub.put_identity(identity(email: user.email, email_verified: true))

      assert {:ok, %User{id: id}} = Accounts.sso_sign_in("google", %{}, %{})
      assert id == user.id
      assert Repo.get_by(UserIdentity, provider: "google", provider_uid: "uid-1").user_id == user.id
    end

    test "new verified email creates a confirmed user and an identity" do
      email = unique_user_email()
      Stub.put_identity(identity(email: email, email_verified: true))

      assert {:ok, %User{} = user} = Accounts.sso_sign_in("google", %{}, %{})
      assert user.email == email
      assert user.confirmed_at
      assert Repo.get_by(UserIdentity, provider: "google", provider_uid: "uid-1").user_id == user.id
    end

    test "unverified email colliding with an existing user is rejected" do
      user = user_fixture()
      Stub.put_identity(identity(email: user.email, email_verified: false))

      assert {:error, :email_taken} = Accounts.sso_sign_in("google", %{}, %{})
      refute Repo.get_by(UserIdentity, provider: "google", provider_uid: "uid-1")
    end

    test "missing email is rejected" do
      Stub.put_identity(identity(email: nil))
      assert {:error, :email_required} = Accounts.sso_sign_in("google", %{}, %{})
    end

    test "adapter error is passed through" do
      Stub.put_error(:provider_down)
      assert {:error, :provider_down} = Accounts.sso_sign_in("google", %{}, %{})
    end
  end

  describe "configured_providers/0" do
    test "returns only configured providers in display order" do
      Application.put_env(:perfect_paper, :oauth_providers, %{
        "github" => [client_id: "x", client_secret: "y"],
        "google" => [client_id: "x", client_secret: "y"]
      })

      on_exit(fn -> Application.put_env(:perfect_paper, :oauth_providers, %{}) end)

      assert Accounts.configured_providers() == ["google", "github"]
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/perfect_paper/accounts_sso_test.exs`
Expected: FAIL — `Accounts.sso_sign_in/3` undefined.

- [ ] **Step 3: Implement the context functions**

In `lib/perfect_paper/accounts.ex`, add `alias`es if missing (`UserIdentity`, `OAuth`) and add this section after `register_user_with_password/1`:

```elixir
  ## Social sign-in (SSO)

  @display_order ~w(google microsoft orcid github apple)

  @doc "Builds the provider authorize URL (delegates to the OAuth adapter)."
  @spec sso_authorize_url(String.t()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  def sso_authorize_url(provider) do
    OAuth.adapter().authorize_url(provider)
  end

  @doc """
  Completes a provider callback and resolves it to a user, applying the linking
  rules (known identity → auto-link verified → create → reject unverified
  collision → reject missing email).
  """
  @spec sso_sign_in(String.t(), map(), map()) ::
          {:ok, User.t()} | {:error, :email_taken | :email_required | term()}
  def sso_sign_in(provider, params, session_params) do
    with {:ok, identity} <- OAuth.adapter().callback(provider, params, session_params) do
      resolve_identity(identity)
    end
  end

  @doc "Providers that have credentials configured, in display order."
  @spec configured_providers() :: [String.t()]
  def configured_providers do
    configured = Application.get_env(:perfect_paper, :oauth_providers, %{})
    Enum.filter(@display_order, &Map.has_key?(configured, &1))
  end

  defp resolve_identity(%{provider: provider, uid: uid} = identity) do
    case Repo.get_by(UserIdentity, provider: provider, provider_uid: uid) do
      %UserIdentity{} = link ->
        {:ok, Repo.get!(User, link.user_id)}

      nil ->
        link_or_create(identity)
    end
  end

  defp link_or_create(%{email: nil}), do: {:error, :email_required}

  defp link_or_create(%{email: email, email_verified: verified} = identity) do
    case {Repo.get_by(User, email: email), verified} do
      {%User{} = user, true} -> link_identity(user, identity)
      {%User{}, false} -> {:error, :email_taken}
      {nil, _} -> create_user_with_identity(identity)
    end
  end

  defp link_identity(user, identity) do
    case Repo.insert(identity_changeset(user.id, identity)) do
      {:ok, _} -> {:ok, user}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp create_user_with_identity(%{email: email} = identity) do
    user_changeset =
      %User{}
      |> User.email_changeset(%{email: email})
      |> User.confirm_changeset()

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:user, user_changeset)
      |> Ecto.Multi.insert(:identity, fn %{user: user} ->
        identity_changeset(user.id, identity)
      end)

    case Repo.transaction(multi) do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  defp identity_changeset(user_id, %{provider: provider, uid: uid, email: email}) do
    UserIdentity.changeset(%UserIdentity{}, %{
      user_id: user_id,
      provider: provider,
      provider_uid: uid,
      provider_email: email
    })
  end
```

Note: `User.confirm_changeset/1` takes a `User` struct or changeset via `change/1`; it is defined as `change(user, confirmed_at: now)`. Piping an `Ecto.Changeset` into it works because `change/1` accepts a changeset. If `confirm_changeset/1` rejects a changeset in this codebase, instead set confirmation by inserting the user first, then `User.confirm_changeset(user)` in a second `Multi.update`. Verify by reading `lib/perfect_paper/accounts/user.ex` `confirm_changeset/1` before implementing; adjust to whichever form compiles.

- [ ] **Step 4: Ensure aliases**

Confirm the top of `lib/perfect_paper/accounts.ex` aliases `UserIdentity` and `OAuth`. The module already does `alias PerfectPaper.Accounts.{User, UserToken, UserNotifier}` — extend it to:

```elixir
  alias PerfectPaper.Accounts.{User, UserToken, UserNotifier, UserIdentity, OAuth}
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/perfect_paper/accounts_sso_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/accounts.ex test/perfect_paper/accounts_sso_test.exs
git commit -m "feat(sso): Accounts.sso_sign_in linking logic + configured_providers"
```

---

## Task 6: Assent adapter (Google + GitHub)

**Files:**
- Create: `lib/perfect_paper/accounts/oauth/assent.ex`
- Test: `test/perfect_paper/accounts/oauth/assent_test.exs`

The provider HTTP path can't be unit-tested without live calls, so we test the **pure normalisation** (`normalize/2`) and the unconfigured-provider path; the live exchange is covered by the user's per-provider manual verification.

- [ ] **Step 1: Write the failing test**

Create `test/perfect_paper/accounts/oauth/assent_test.exs`:

```elixir
defmodule PerfectPaper.Accounts.OAuth.AssentTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Accounts.OAuth.Assent, as: Adapter

  test "normalises OIDC-style claims (Google)" do
    claims = %{
      "sub" => "108",
      "email" => "p@example.com",
      "email_verified" => true,
      "name" => "Pat"
    }

    assert Adapter.normalize("google", claims) == %{
             provider: "google",
             uid: "108",
             email: "p@example.com",
             email_verified: true,
             name: "Pat"
           }
  end

  test "treats a GitHub email as verified when present (Assent returns the primary verified email)" do
    claims = %{"sub" => "42", "email" => "dev@example.com", "name" => "Dev"}
    identity = Adapter.normalize("github", claims)
    assert identity.uid == "42"
    assert identity.email == "dev@example.com"
    assert identity.email_verified == true
  end

  test "github with no email is unverified with nil email" do
    identity = Adapter.normalize("github", %{"sub" => "42"})
    assert identity.email == nil
    assert identity.email_verified == false
  end

  test "authorize_url errors for an unconfigured provider" do
    assert {:error, :unconfigured_provider} = Adapter.authorize_url("google")
  end
end
```

(The last test assumes `:oauth_providers` is `%{}` in test config, which Task 1 set.)

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/perfect_paper/accounts/oauth/assent_test.exs`
Expected: FAIL — adapter undefined.

- [ ] **Step 3: Implement the adapter**

Create `lib/perfect_paper/accounts/oauth/assent.ex`:

```elixir
defmodule PerfectPaper.Accounts.OAuth.Assent do
  @moduledoc """
  Default OAuth adapter, backed by Assent. The only module that references
  Assent strategies or provider claim shapes. Reads per-provider credentials
  from `config :perfect_paper, :oauth_providers`.
  """
  @behaviour PerfectPaper.Accounts.OAuth

  @strategies %{
    "google" => Assent.Strategy.Google,
    "github" => Assent.Strategy.Github
  }

  @impl true
  def authorize_url(provider) do
    with {:ok, {strategy, config}} <- provider_config(provider) do
      strategy.authorize_url(config)
    end
  end

  @impl true
  def callback(provider, params, session_params) do
    with {:ok, {strategy, config}} <- provider_config(provider) do
      config = Keyword.put(config, :session_params, session_params)

      case strategy.callback(config, params) do
        {:ok, %{user: user}} -> {:ok, normalize(provider, user)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Normalises provider claims into the `OAuth.identity` map. OIDC providers
  (Google) carry `email_verified`; GitHub does not, but Assent's GitHub strategy
  only ever returns the account's primary *verified* email, so a present email
  is treated as verified.
  """
  @spec normalize(String.t(), map()) :: PerfectPaper.Accounts.OAuth.identity()
  def normalize(provider, claims) do
    email = claims["email"]

    %{
      provider: provider,
      uid: to_string(claims["sub"]),
      email: email,
      email_verified: email_verified?(provider, claims),
      name: claims["name"]
    }
  end

  defp email_verified?("github", claims), do: not is_nil(claims["email"])
  defp email_verified?(_provider, claims), do: claims["email_verified"] == true

  defp provider_config(provider) do
    providers = Application.get_env(:perfect_paper, :oauth_providers, %{})

    with %{} = opts <- Map.get(providers, provider),
         strategy when not is_nil(strategy) <- @strategies[provider] do
      config =
        opts
        |> Keyword.put_new(:http_adapter, Assent.HTTPAdapter.Req)
        |> Keyword.put(:redirect_uri, redirect_uri(provider))

      {:ok, {strategy, config}}
    else
      _ -> {:error, :unconfigured_provider}
    end
  end

  defp redirect_uri(provider) do
    PerfectPaperWeb.Endpoint.url() <> "/auth/#{provider}/callback"
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `mix test test/perfect_paper/accounts/oauth/assent_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/accounts/oauth/assent.ex test/perfect_paper/accounts/oauth/assent_test.exs
git commit -m "feat(sso): Assent adapter for Google + GitHub"
```

---

## Task 7: OAuthController + routes

**Files:**
- Create: `lib/perfect_paper_web/controllers/oauth_controller.ex`
- Modify: `lib/perfect_paper_web/router.ex`
- Test: `test/perfect_paper_web/controllers/oauth_controller_test.exs`

- [ ] **Step 1: Write the failing controller test**

Create `test/perfect_paper_web/controllers/oauth_controller_test.exs`:

```elixir
defmodule PerfectPaperWeb.OAuthControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Accounts.OAuth.Stub

  describe "GET /auth/:provider" do
    test "redirects to the provider authorize url", %{conn: conn} do
      conn = get(conn, ~p"/auth/google")
      assert redirected_to(conn) =~ "example.test/auth/google"
      assert get_session(conn, :oauth_session_params)
    end
  end

  describe "GET /auth/:provider/callback" do
    test "logs in on a successful identity", %{conn: conn} do
      email = unique_user_email()
      Stub.put_identity(%{provider: "google", uid: "u1", email: email, email_verified: true, name: "X"})

      conn =
        conn
        |> init_test_session(%{oauth_session_params: %{state: "s"}})
        |> get(~p"/auth/google/callback", %{"code" => "abc", "state" => "s"})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
    end

    test "redirects to login with a flash when the email is already taken", %{conn: conn} do
      user = user_fixture()
      Stub.put_identity(%{provider: "google", uid: "u2", email: user.email, email_verified: false, name: "X"})

      conn =
        conn
        |> init_test_session(%{oauth_session_params: %{state: "s"}})
        |> get(~p"/auth/google/callback", %{"code" => "abc", "state" => "s"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already"
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/perfect_paper_web/controllers/oauth_controller_test.exs`
Expected: FAIL — no route / controller.

- [ ] **Step 3: Create the controller**

Create `lib/perfect_paper_web/controllers/oauth_controller.ex`:

```elixir
defmodule PerfectPaperWeb.OAuthController do
  @moduledoc """
  Drives the OAuth redirect round-trip for social sign-in. `request/2` sends the
  browser to the provider; `callback/2` exchanges the code, resolves the user
  through `Accounts.sso_sign_in/3`, and logs them in.
  """
  use PerfectPaperWeb, :controller

  alias PerfectPaper.Accounts
  alias PerfectPaperWeb.UserAuth

  def request(conn, %{"provider" => provider}) do
    case Accounts.sso_authorize_url(provider) do
      {:ok, %{url: url, session_params: session_params}} ->
        conn
        |> put_session(:oauth_session_params, session_params)
        |> redirect(external: url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That sign-in option isn't available right now.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def callback(conn, %{"provider" => provider} = params) do
    session_params = get_session(conn, :oauth_session_params) || %{}

    conn = delete_session(conn, :oauth_session_params)

    case Accounts.sso_sign_in(provider, params, session_params) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user)

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp error_message(:email_taken),
    do: "That email already has an account. Log in, then link this provider in Settings."

  defp error_message(:email_required),
    do: "That provider didn't share an email. Try signing up with your email instead."

  defp error_message(_other), do: "Sign-in failed. Please try again."
end
```

- [ ] **Step 4: Add routes**

In `lib/perfect_paper_web/router.ex`, inside the existing public `scope "/", PerfectPaperWeb do` block that uses the `:browser` pipeline (the one with `/users/register` / `/users/log-in`), add:

```elixir
    get "/auth/:provider", OAuthController, :request
    get "/auth/:provider/callback", OAuthController, :callback
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/perfect_paper_web/controllers/oauth_controller_test.exs`
Expected: PASS (3 tests). If `log_in_user/2` renews the session and the assertion on `:user_token` needs a different key, read `lib/perfect_paper_web/user_auth.ex` `log_in_user/3` to confirm the session key name and adjust the assertion (do not weaken — match the real key).

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/controllers/oauth_controller.ex lib/perfect_paper_web/router.ex test/perfect_paper_web/controllers/oauth_controller_test.exs
git commit -m "feat(sso): OAuthController + /auth routes"
```

---

## Task 8: Social-button UI on register + login

**Files:**
- Create: `lib/perfect_paper_web/components/auth_providers.ex`
- Modify: `lib/perfect_paper_web/live/user_live/registration.ex` (render)
- Modify: `lib/perfect_paper_web/live/user_live/login.ex` (render)
- Test: `test/perfect_paper_web/live/user_live/registration_test.exs` (add one case)

- [ ] **Step 1: Create the social-buttons component**

Create `lib/perfect_paper_web/components/auth_providers.ex`:

```elixir
defmodule PerfectPaperWeb.AuthProviders do
  @moduledoc """
  Renders a row of social sign-in buttons for the currently configured
  providers, with an "or" divider. Renders nothing when none are configured.
  Each button is a full-page link to the OAuth controller (not a LiveView event).
  """
  use PerfectPaperWeb, :html

  alias PerfectPaper.Accounts

  @labels %{
    "google" => "Google",
    "github" => "GitHub",
    "microsoft" => "Microsoft",
    "orcid" => "ORCID",
    "apple" => "Apple"
  }

  @doc "Social sign-in row. Pass no assigns."
  attr :rest, :global

  def provider_buttons(assigns) do
    assigns = assign(assigns, :providers, Accounts.configured_providers())

    ~H"""
    <div :if={@providers != []} class="space-y-4" {@rest}>
      <div class="grid grid-cols-3 gap-2">
        <.link
          :for={provider <- @providers}
          href={~p"/auth/#{provider}"}
          class="btn btn-outline flex items-center justify-center gap-2"
          aria-label={"Continue with #{label(provider)}"}
        >
          {icon(%{provider: provider})}
          <span class="sr-only">{label(provider)}</span>
        </.link>
      </div>
      <div class="divider text-xs text-base-content/50">or</div>
    </div>
    """
  end

  defp label(provider), do: Map.get(@labels, provider, provider)

  # Minimal monochrome brand marks (currentColor) — enough to be recognisable;
  # swap for full-colour SVGs later if desired.
  defp icon(%{provider: "google"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class="size-5" fill="currentColor" aria-hidden="true">
      <path d="M12 11v2.8h4a3.4 3.4 0 0 1-1.5 2.2v1.8h2.4A7.3 7.3 0 0 0 19.6 12c0-.5 0-1-.1-1.4H12z" />
      <path d="M12 20a7.6 7.6 0 0 0 5.3-1.9l-2.4-1.8a4.6 4.6 0 0 1-7-2.4H5.4v1.9A8 8 0 0 0 12 20z" />
      <path d="M9.9 13.9a4.7 4.7 0 0 1 0-3l-2.5-1.9a8 8 0 0 0 0 6.8l2.5-1.9z" />
      <path d="M12 7.6a4.3 4.3 0 0 1 3 1.2l2.2-2.2A7.7 7.7 0 0 0 12 4a8 8 0 0 0-6.6 3.9l2.5 1.9A4.6 4.6 0 0 1 12 7.6z" />
    </svg>
    """
  end

  defp icon(%{provider: "github"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class="size-5" fill="currentColor" aria-hidden="true">
      <path d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48l-.01-1.7c-2.78.6-3.37-1.34-3.37-1.34-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.6.07-.6 1 .07 1.53 1.03 1.53 1.03.9 1.53 2.36 1.09 2.94.83.09-.65.35-1.09.63-1.34-2.22-.25-4.55-1.11-4.55-4.94 0-1.09.39-1.98 1.03-2.68-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.02a9.6 9.6 0 0 1 5 0c1.91-1.29 2.75-1.02 2.75-1.02.55 1.38.2 2.4.1 2.65.64.7 1.03 1.59 1.03 2.68 0 3.84-2.34 4.69-4.57 4.94.36.31.68.92.68 1.85l-.01 2.75c0 .27.18.58.69.48A10 10 0 0 0 12 2z" />
    </svg>
    """
  end

  defp icon(assigns), do: ~H"<span class=\"font-semibold\">{label(@provider)}</span>"
end
```

- [ ] **Step 2: Add a failing UI test**

In `test/perfect_paper_web/live/user_live/registration_test.exs`, add inside the "Registration page" describe block:

```elixir
    test "shows social buttons when a provider is configured", %{conn: conn} do
      Application.put_env(:perfect_paper, :oauth_providers, %{
        "google" => [client_id: "x", client_secret: "y"]
      })

      on_exit(fn -> Application.put_env(:perfect_paper, :oauth_providers, %{}) end)

      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "/auth/google"
    end
```

- [ ] **Step 3: Run to verify failure**

Run: `mix test test/perfect_paper_web/live/user_live/registration_test.exs`
Expected: the new "shows social buttons when a provider is configured" test FAILS (buttons not rendered yet); the rest still pass.

- [ ] **Step 4: Render the component on both pages**

In `lib/perfect_paper_web/live/user_live/registration.ex`, add `import PerfectPaperWeb.AuthProviders` near the top (after `use PerfectPaperWeb, :live_view`), and in `render/1` place the row directly above the mode-toggle tabs (inside the `<div :if={!@check_email} ...>`):

```heex
          <.provider_buttons />
```

In `lib/perfect_paper_web/live/user_live/login.ex`, add the same `import` and render `<.provider_buttons />` above the login form (inside the `:if={!@check_email}` / form area).

- [ ] **Step 5: Run the registration tests**

Run: `mix test test/perfect_paper_web/live/user_live/registration_test.exs`
Expected: PASS (existing + new social-button test).

- [ ] **Step 6: Verify compile and login renders**

Run: `mix compile --warnings-as-errors` then `mix test test/perfect_paper_web/live/user_live/login_test.exs`
Expected: clean compile; login tests still PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/perfect_paper_web/components/auth_providers.ex lib/perfect_paper_web/live/user_live/registration.ex lib/perfect_paper_web/live/user_live/login.ex test/perfect_paper_web/live/user_live/registration_test.exs
git commit -m "feat(sso): social sign-in buttons on register + login"
```

---

## Task 9: Runtime credentials wiring + setup docs

**Files:**
- Modify: `config/runtime.exs`
- Create: `docs/oauth-setup.md`

- [ ] **Step 1: Wire env vars into provider config**

In `config/runtime.exs`, add a block that assembles `:oauth_providers` from env vars (include a provider only when both its id and secret are set):

```elixir
oauth_providers =
  %{}
  |> then(fn acc ->
    if (id = System.get_env("GOOGLE_CLIENT_ID")) && (secret = System.get_env("GOOGLE_CLIENT_SECRET")) do
      Map.put(acc, "google", client_id: id, client_secret: secret)
    else
      acc
    end
  end)
  |> then(fn acc ->
    if (id = System.get_env("GITHUB_CLIENT_ID")) && (secret = System.get_env("GITHUB_CLIENT_SECRET")) do
      Map.put(acc, "github", client_id: id, client_secret: secret)
    else
      acc
    end
  end)

config :perfect_paper, :oauth_providers, oauth_providers
```

Place it so it runs in all environments (outside the `if config_env() == :prod` guard) so dev picks up the vars too.

- [ ] **Step 2: Verify it boots without any provider env set**

Run: `mix compile` and `MIX_ENV=dev mix run -e "IO.inspect(Application.get_env(:perfect_paper, :oauth_providers))"`
Expected: prints `%{}` (no providers configured) with no error.

- [ ] **Step 3: Write the setup checklist**

Create `docs/oauth-setup.md` documenting, for Google and GitHub: where to register the app, the exact redirect URI `https://<host>/auth/<provider>/callback` (and the dev URI `http://localhost:4000/auth/<provider>/callback`), the scopes (Google: `openid email profile`; GitHub: `user:email`), and the env var names (`GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`, `GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET`). State that a provider's button only appears once its env vars are set and the server is restarted.

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs docs/oauth-setup.md
git commit -m "feat(sso): runtime credential wiring + Google/GitHub setup docs"
```

---

## Task 10: Pre-merge verification

**Files:** none (verification + git)

- [ ] **Step 1: Run the SSO + auth suite**

Run: `mix test test/perfect_paper/accounts_sso_test.exs test/perfect_paper/accounts/ test/perfect_paper_web/controllers/oauth_controller_test.exs test/perfect_paper_web/live/user_live/`
Expected: all PASS.

- [ ] **Step 2: Full precommit**

Run: `mix precommit`
Expected: compile (warnings-as-errors), format, full suite all green. Fix anything red — including unrelated tests that assert old behaviour.

- [ ] **Step 3: Manual smoke (no credentials needed)**

Run the dev server, open `/users/register`: with no provider env set, **no** social row appears (only the tabs). Set `GITHUB_CLIENT_ID`/`SECRET` dummy values and restart: a GitHub button appears linking to `/auth/github`. (Clicking it requires real credentials to complete — that's the user's live step.)

- [ ] **Step 4: Report**

Report: which tasks completed, test counts, and the per-provider live-verification still owed to the user.

---

## Notes for the implementer

- **No real provider HTTP in tests** — config selects the Stub adapter in `test.exs`. Never call Google/GitHub from a test.
- **`confirm_changeset/1` shape:** read it before Task 5 Step 3 and use whichever form (struct vs changeset) compiles; new social users must end up with `confirmed_at` set.
- **Session key for login:** confirm the real session key set by `UserAuth.log_in_user/3` and assert on that exact key in the controller test.
- **Anti-enumeration is not a goal here** — social sign-in legitimately reveals "this email already has an account" via the `:email_taken` flash; that is the chosen UX, distinct from the magic-link page's anti-enumeration.
- **Adding a provider later** (Phase 2/3) = add its strategy to `@strategies`, its env block in `runtime.exs`, its label/icon, and (Apple) JWT-secret handling — no changes to the linking logic.
```
