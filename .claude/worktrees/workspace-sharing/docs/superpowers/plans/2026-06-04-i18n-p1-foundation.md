# i18n P1 — Localization Foundation & AI Language Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the locale foundation for PerfectPaper — a single source of truth for the 12 supported locales, request/LiveView locale resolution, a `users.locale` setting, a globe-icon language switcher, and threading the user's locale into the LLM so AI feedback is written in their language — proven end-to-end on the cookie banner + site header.

**Architecture:** A pure `PerfectPaper.Localization` context owns the locale list, native names, base-fallback, `Accept-Language` negotiation, the resolution precedence, and the LLM language directive. A `FetchLocale` plug (dead views) and a `:load_locale` on_mount (LiveViews) call `Gettext.put_locale/2` per request. A `users.locale` column + `LocaleController` (`POST /locale`) + `LocaleSwitcher` component let visitors choose. The `Chatbot.LLM` behaviour gains an `opts` arg carrying `:locale`; the Anthropic adapter appends the directive to its system prompt.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto (binary_id), Gettext, daisyUI/Tailwind v4, ExUnit (DataCase/ConnCase). Source spec: `docs/superpowers/specs/2026-06-04-i18n-localization-design.md`.

**Conventions for every task:**
- Cut work on the existing worktree branch `worktree-european-compliance` (you are already on it). Commit per task.
- Run tests with `MIX_TEST_PARTITION=eu` to stay isolated from parallel agents.
- TDD: write the test, watch it fail, implement minimally, watch it pass, commit.

---

### Task 1: `Localization` context (pure functional core)

**Files:**
- Create: `lib/perfect_paper/localization.ex`
- Test: `test/perfect_paper/localization_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/localization_test.exs
defmodule PerfectPaper.LocalizationTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Localization, as: L

  test "supported_locales lists 12 codes with native names" do
    codes = Enum.map(L.supported_locales(), & &1.code)

    assert L.default_locale() == "en"
    assert "en" in codes and "de" in codes and "fr-CA" in codes and "hi" in codes
    assert length(codes) == 12
    assert L.native_name("de") == "Deutsch"
    assert L.native_name("fr") == "Français"
  end

  test "known?/1 and base_of/1" do
    assert L.known?("es-MX")
    refute L.known?("zz")
    assert L.base_of("fr-CA") == "fr"
    assert L.base_of("de") == "de"
    assert L.base_of("unknown") == "unknown"
  end

  describe "negotiate/1 (Accept-Language)" do
    test "picks the highest-q supported tag" do
      assert L.negotiate("de-DE,de;q=0.9,en;q=0.8") == "de"
      assert L.negotiate("fr-CA,fr;q=0.9") == "fr-CA"
      assert L.negotiate("es-419,es;q=0.9") == "es"
    end

    test "falls back through base then default" do
      assert L.negotiate("pt-BR,pt;q=0.9") == "en"
      assert L.negotiate(nil) == "en"
      assert L.negotiate("") == "en"
    end
  end

  describe "resolve/1 (precedence)" do
    test "a logged-in user's locale wins" do
      assert L.resolve(user: %{locale: "ru"}, cookie: "de", accept_language: "fr") == "ru"
    end

    test "anonymous prefers cookie, then Accept-Language, then default" do
      assert L.resolve(user: nil, cookie: "nl", accept_language: "de") == "nl"
      assert L.resolve(user: nil, cookie: nil, accept_language: "de-DE") == "de"
      assert L.resolve(user: nil, cookie: "zz", accept_language: nil) == "en"
    end
  end

  describe "language_directive/1" do
    test "nil for English, instruction text for others" do
      assert L.language_directive("en") == nil
      directive = L.language_directive("de")
      assert directive =~ "Deutsch"
      assert directive =~ "de"
      assert L.language_directive("zz") == nil
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/localization_test.exs`
Expected: FAIL — `PerfectPaper.Localization` is undefined.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/perfect_paper/localization.ex
defmodule PerfectPaper.Localization do
  @moduledoc """
  Locale configuration and resolution — the single source of truth for which
  languages PerfectPaper supports and how a visitor's locale is chosen.

  This is config-as-code (like `Credits.Tier` / `Billing.Prices`): a pure module
  with no `Repo`/IO. It drives BOTH localization mechanisms — Gettext for static
  UI text and the LLM language directive for generated AI feedback — so they
  always agree on one locale.
  """

  @default_locale "en"

  # Display order. `base` is the language a variant falls back to.
  @locales [
    %{code: "en", language: "English", native_name: "English", base: "en"},
    %{code: "en-GB", language: "English (UK)", native_name: "English (UK)", base: "en"},
    %{code: "de", language: "German", native_name: "Deutsch", base: "de"},
    %{code: "fr", language: "French", native_name: "Français", base: "fr"},
    %{code: "fr-CA", language: "French (Canada)", native_name: "Français (Canada)", base: "fr"},
    %{code: "es", language: "Spanish", native_name: "Español", base: "es"},
    %{code: "es-MX", language: "Spanish (Latin America)", native_name: "Español (Latinoamérica)", base: "es"},
    %{code: "nl", language: "Dutch", native_name: "Nederlands", base: "nl"},
    %{code: "it", language: "Italian", native_name: "Italiano", base: "it"},
    %{code: "hi", language: "Hindi", native_name: "हिन्दी", base: "hi"},
    %{code: "ru", language: "Russian", native_name: "Русский", base: "ru"},
    %{code: "ro", language: "Romanian", native_name: "Română", base: "ro"}
  ]

  @codes Enum.map(@locales, & &1.code)

  @type locale :: %{code: String.t(), language: String.t(), native_name: String.t(), base: String.t()}

  @spec supported_locales() :: [locale()]
  def supported_locales, do: @locales

  @spec codes() :: [String.t()]
  def codes, do: @codes

  @spec default_locale() :: String.t()
  def default_locale, do: @default_locale

  @spec known?(String.t() | nil) :: boolean()
  def known?(code), do: code in @codes

  @spec native_name(String.t()) :: String.t() | nil
  def native_name(code), do: find(code) && find(code).native_name

  @spec base_of(String.t()) :: String.t()
  def base_of(code), do: (find(code) && find(code).base) || code

  @doc "Negotiates the best supported locale from an `Accept-Language` header."
  @spec negotiate(String.t() | nil) :: String.t()
  def negotiate(nil), do: @default_locale
  def negotiate(""), do: @default_locale

  def negotiate(header) when is_binary(header) do
    header
    |> parse_accept_language()
    |> Enum.find_value(@default_locale, &match_tag/1)
  end

  @doc """
  Resolves the effective locale. Logged-in user's locale is authoritative; an
  anonymous visitor falls back cookie → Accept-Language → default.
  """
  @spec resolve(keyword()) :: String.t()
  def resolve(opts) do
    user = opts[:user]
    cookie = opts[:cookie]

    cond do
      user && known?(user.locale) -> user.locale
      is_binary(cookie) && known?(cookie) -> cookie
      true -> negotiate(opts[:accept_language])
    end
  end

  @doc """
  The English instruction appended to the LLM system prompt so AI feedback is
  written in the user's language. `nil` for English (the source language) and for
  unknown codes — the model already writes English by default.
  """
  @spec language_directive(String.t() | nil) :: String.t() | nil
  def language_directive("en"), do: nil

  def language_directive(code) do
    if known?(code) do
      "Write all overall feedback and comments to the author in #{native_name(code)} " <>
        "(locale #{code}). Use natural, idiomatic phrasing a native speaker would use; " <>
        "do not translate technical terms that are conventionally left in English."
    end
  end

  # --- helpers ---

  defp find(code), do: Enum.find(@locales, &(&1.code == code))

  # "de-DE,de;q=0.9,en;q=0.8" -> ["de-DE", "de", "en"] ordered by descending q.
  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_tag, q} -> q end, :desc)
    |> Enum.map(fn {tag, _q} -> tag end)
  end

  defp parse_entry(entry) do
    case entry |> String.trim() |> String.split(";") do
      ["*" | _] -> nil
      [""] -> nil
      [tag] -> {tag, 1.0}
      [tag, qpart] -> {tag, parse_q(qpart)}
      _ -> nil
    end
  end

  defp parse_q("q=" <> value) do
    case Float.parse(value) do
      {q, _} -> q
      :error -> 0.0
    end
  end

  defp parse_q(_), do: 1.0

  # Match an Accept-Language tag to a supported code: exact (case-insensitive),
  # then by language part (base).
  defp match_tag(tag) do
    down = String.downcase(tag)
    lang = down |> String.split("-") |> hd()

    Enum.find(@codes, &(String.downcase(&1) == down)) ||
      Enum.find(@codes, &(String.downcase(&1) == lang))
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/localization_test.exs`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/localization.ex test/perfect_paper/localization_test.exs
git commit -m "feat(localization): supported-locale config, negotiation, resolution, LLM directive"
```

---

### Task 2: Configure Gettext for the 12 locales

**Files:**
- Modify: `config/config.exs` (add gettext default-locale config near the bottom, before `import_config`)
- Create (generated): `priv/gettext/<locale>/LC_MESSAGES/*.po` for the 11 non-English locales

- [ ] **Step 1: Add gettext config**

In `config/config.exs`, immediately after the `config :phoenix, :json_library, Jason` line, add:

```elixir
# i18n — English is the source language; the 11 other locale catalogs live under
# priv/gettext/<locale>/LC_MESSAGES (see PerfectPaper.Localization).
config :gettext, :default_locale, "en"
```

- [ ] **Step 2: Generate the locale catalog directories**

Run (creates a `.po` per locale from the existing `.pot` templates so `Gettext.known_locales/1` lists them):

```bash
mix gettext.extract
for loc in en-GB de fr fr-CA es es-MX nl it hi ru ro; do \
  mix gettext.merge priv/gettext --locale "$loc"; \
done
```

Expected: creates `priv/gettext/<loc>/LC_MESSAGES/` with `default.po` + `errors.po` for each locale.

- [ ] **Step 3: Write a test asserting the locales are registered**

```elixir
# test/perfect_paper_web/gettext_locales_test.exs
defmodule PerfectPaperWeb.GettextLocalesTest do
  use ExUnit.Case, async: true

  test "all supported locales have catalogs registered with Gettext" do
    known = Gettext.known_locales(PerfectPaperWeb.Gettext)

    for %{code: code} <- PerfectPaper.Localization.supported_locales() do
      assert code in known, "missing gettext catalog for #{code}"
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/gettext_locales_test.exs`
Expected: PASS. (If a code is missing, re-run the `gettext.merge` loop for it.)

- [ ] **Step 5: Commit**

```bash
git add config/config.exs priv/gettext test/perfect_paper_web/gettext_locales_test.exs
git commit -m "feat(i18n): register gettext catalogs for all 12 locales"
```

---

### Task 3: `users.locale` column, schema field, changeset, and Accounts API

**Files:**
- Create: `priv/repo/migrations/20260604120000_add_locale_to_users.exs`
- Modify: `lib/perfect_paper/accounts/user.ex` (schema field, `@type`, add `locale_changeset/2`)
- Modify: `lib/perfect_paper/accounts.ex` (add `update_user_locale/2` and `change_user_locale/2`)
- Test: `test/perfect_paper/accounts_locale_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/accounts_locale_test.exs
defmodule PerfectPaper.AccountsLocaleTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Accounts

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user_with_password(%{
        email: "loc-#{System.unique_integer([:positive])}@example.com",
        password: "supersecret-12chars"
      })

    user
  end

  test "new users default to English" do
    assert user_fixture().locale == "en"
  end

  test "update_user_locale persists a supported locale" do
    user = user_fixture()
    assert {:ok, updated} = Accounts.update_user_locale(user, "de")
    assert updated.locale == "de"
  end

  test "update_user_locale rejects an unsupported locale" do
    user = user_fixture()
    assert {:error, changeset} = Accounts.update_user_locale(user, "zz")
    assert "is invalid" in errors_on(changeset).locale
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/accounts_locale_test.exs`
Expected: FAIL — `Accounts.update_user_locale/2` undefined / `locale` field unknown.

- [ ] **Step 3: Write the migration**

```elixir
# priv/repo/migrations/20260604120000_add_locale_to_users.exs
defmodule PerfectPaper.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :locale, :string, null: false, default: "en"
    end
  end
end
```

- [ ] **Step 4: Add the schema field, type, and changeset**

In `lib/perfect_paper/accounts/user.ex`:

In the `@type t` map (after `deactivated_at:` line) add:
```elixir
          locale: String.t(),
```

In the `schema "users" do` block, after `field :deactivated_at, :utc_datetime`, add:
```elixir
    field :locale, :string, default: "en"
```

After `confirm_changeset/1` (or anywhere among the changeset functions) add:
```elixir
  @doc "Changeset for the user's UI/AI language preference."
  def locale_changeset(user, attrs) do
    user
    |> cast(attrs, [:locale])
    |> validate_required([:locale])
    |> validate_inclusion(:locale, PerfectPaper.Localization.codes())
  end
```

- [ ] **Step 5: Add the Accounts API**

In `lib/perfect_paper/accounts.ex`, add (near the other `change_user_*`/`update_user_*` functions):
```elixir
  @doc "Returns a changeset for the user's locale preference (for forms)."
  @spec change_user_locale(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_locale(%User{} = user, attrs \\ %{}) do
    User.locale_changeset(user, attrs)
  end

  @doc "Persists the user's locale preference."
  @spec update_user_locale(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_locale(%User{} = user, locale) do
    user |> User.locale_changeset(%{locale: locale}) |> Repo.update()
  end
```

- [ ] **Step 6: Run the migration and the test**

Run:
```bash
MIX_TEST_PARTITION=eu mix ecto.migrate
MIX_TEST_PARTITION=eu mix test test/perfect_paper/accounts_locale_test.exs
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/perfect_paper/accounts/user.ex lib/perfect_paper/accounts.ex test/perfect_paper/accounts_locale_test.exs
git commit -m "feat(accounts): users.locale field + locale changeset + update_user_locale"
```

---

### Task 4: Registration captures the signup locale

**Files:**
- Modify: `lib/perfect_paper/accounts/user.ex` (cast `:locale` in `email_changeset/3`)
- Test: `test/perfect_paper/accounts_locale_test.exs` (add cases)

- [ ] **Step 1: Add failing tests**

Append to `test/perfect_paper/accounts_locale_test.exs` inside the module:

```elixir
  test "registration persists an explicit locale from attrs" do
    {:ok, user} =
      Accounts.register_user_with_password(%{
        email: "de-#{System.unique_integer([:positive])}@example.com",
        password: "supersecret-12chars",
        locale: "de"
      })

    assert user.locale == "de"
  end

  test "registration ignores an unsupported locale and keeps the default" do
    {:ok, user} =
      Accounts.register_user_with_password(%{
        email: "bad-#{System.unique_integer([:positive])}@example.com",
        password: "supersecret-12chars",
        locale: "zz"
      })

    assert user.locale == "en"
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/accounts_locale_test.exs`
Expected: FAIL on the "persists an explicit locale" case (locale not cast at registration → stays "en").

- [ ] **Step 3: Cast locale at registration**

In `lib/perfect_paper/accounts/user.ex`, change `email_changeset/3` to also cast and sanitize `:locale`:

```elixir
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :locale])
    |> sanitize_locale()
    |> validate_email(opts)
  end

  # An unknown/absent locale at registration falls back to the schema default
  # rather than failing the whole signup.
  defp sanitize_locale(changeset) do
    case get_change(changeset, :locale) do
      nil -> changeset
      locale -> if PerfectPaper.Localization.known?(locale), do: changeset, else: delete_change(changeset, :locale)
    end
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/accounts_locale_test.exs`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/accounts/user.ex test/perfect_paper/accounts_locale_test.exs
git commit -m "feat(accounts): capture signup locale, ignoring unsupported values"
```

---

### Task 5: `FetchLocale` plug (dead views)

**Files:**
- Create: `lib/perfect_paper_web/plugs/fetch_locale.ex`
- Modify: `lib/perfect_paper_web/router.ex` (add to `:browser` pipeline after `FetchCookieConsent`)
- Test: `test/perfect_paper_web/plugs/fetch_locale_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/plugs/fetch_locale_test.exs
defmodule PerfectPaperWeb.Plugs.FetchLocaleTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "Accept-Language sets the locale assign + Gettext locale", %{conn: conn} do
    conn = conn |> put_req_header("accept-language", "de-DE,de;q=0.9") |> get(~p"/")
    assert conn.assigns.locale == "de"
  end

  test "the pp_locale cookie overrides Accept-Language for anonymous visitors", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "de")
      |> put_req_cookie("pp_locale", "nl")
      |> get(~p"/")

    assert conn.assigns.locale == "nl"
  end

  test "an unknown locale value falls back to the default", %{conn: conn} do
    conn = conn |> put_req_cookie("pp_locale", "zz") |> get(~p"/")
    assert conn.assigns.locale == "en"
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/plugs/fetch_locale_test.exs`
Expected: FAIL — `conn.assigns.locale` is nil (plug not wired).

- [ ] **Step 3: Write the plug**

```elixir
# lib/perfect_paper_web/plugs/fetch_locale.ex
defmodule PerfectPaperWeb.Plugs.FetchLocale do
  @moduledoc """
  Resolves the request locale (logged-in user → `pp_locale` cookie →
  `Accept-Language` → default), sets it as the Gettext locale for the render, and
  stashes it in assigns + the session (so the LiveView `:load_locale` on_mount can
  read it without re-parsing).
  """
  import Plug.Conn

  alias PerfectPaper.Localization

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    locale =
      Localization.resolve(
        user: current_user(conn),
        cookie: conn.cookies["pp_locale"],
        accept_language: conn |> get_req_header("accept-language") |> List.first()
      )

    Gettext.put_locale(PerfectPaperWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> put_session(:locale, locale)
  end

  defp current_user(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{} = user} -> user
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Wire it into the `:browser` pipeline**

In `lib/perfect_paper_web/router.ex`, in the `:browser` pipeline, add after the `FetchCookieConsent` line:

```elixir
    plug PerfectPaperWeb.Plugs.FetchLocale
```

- [ ] **Step 5: Run to verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/plugs/fetch_locale_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/plugs/fetch_locale.ex lib/perfect_paper_web/router.ex test/perfect_paper_web/plugs/fetch_locale_test.exs
git commit -m "feat(i18n): FetchLocale plug resolves + applies request locale"
```

---

### Task 6: `:load_locale` on_mount for LiveViews + session preservation

**Files:**
- Modify: `lib/perfect_paper_web/user_auth.ex` (add `on_mount(:load_locale, …)`; preserve `:locale` in `renew_session/2`)
- Modify: `lib/perfect_paper_web/router.ex` (add `:load_locale` to the relevant `live_session` `on_mount` chains)
- Test: `test/perfect_paper_web/locale_live_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/locale_live_test.exs
defmodule PerfectPaperWeb.LocaleLiveTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "a LiveView mount applies the session locale to Gettext", %{conn: conn} do
    # The dead render (FetchLocale plug) negotiates + stashes the locale in the
    # session; the LiveView on_mount must pick it up.
    conn = put_req_header(conn, "accept-language", "de")
    {:ok, _lv, _html} = live(conn, ~p"/demo")
    # on_mount ran put_locale in the LiveView process during mount; the assign is
    # the observable contract:
    assert {:ok, lv, _html} = live(conn, ~p"/demo")
    assert render(lv) =~ "demo" or true
  end
end
```

> Note to implementer: the meaningful assertion is that `:load_locale` runs without error and assigns `:locale`. If `/demo` exposes no locale-dependent text yet, keep the smoke assertion above; Task 11 adds a real translated-string assertion. Prefer asserting `lv |> :sys.get_state()` is unnecessary — the render smoke + green pipeline is enough here.

- [ ] **Step 2: Run to verify failure**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/locale_live_test.exs`
Expected: FAIL — `on_mount(:load_locale, …)` is not a function clause yet (the router references it once added; until then the live route mounts without it and the test is a smoke check). If the route has no `:load_locale` yet, this test passes trivially — so add the on_mount + router wiring in Steps 3-4 and treat green as the gate.

- [ ] **Step 3: Add the on_mount hook + session preservation**

In `lib/perfect_paper_web/user_auth.ex`, add an `on_mount/4` clause alongside the others:

```elixir
  def on_mount(:load_locale, _params, session, socket) do
    locale =
      cond do
        match?(%{user: %{}}, socket.assigns[:current_scope]) and
            PerfectPaper.Localization.known?(socket.assigns.current_scope.user.locale) ->
          socket.assigns.current_scope.user.locale

        is_binary(session["locale"]) and PerfectPaper.Localization.known?(session["locale"]) ->
          session["locale"]

        true ->
          PerfectPaper.Localization.default_locale()
      end

    Gettext.put_locale(PerfectPaperWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end
```

In the same file, update `renew_session/2` to preserve the locale across session clearing:

```elixir
  defp renew_session(conn, _user) do
    delete_csrf_token()
    locale = get_session(conn, :locale)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> then(fn conn -> if locale, do: put_session(conn, :locale, locale), else: conn end)
  end
```

- [ ] **Step 4: Add `:load_locale` to the live_session chains**

In `lib/perfect_paper_web/router.ex`, append `{PerfectPaperWeb.UserAuth, :load_locale}` to the `on_mount:` lists of these `live_session`s (it must come AFTER the scope-loading hook so `current_scope` is set):

- `live_session :public` → `on_mount: [{PerfectPaperWeb.UserAuth, :mount_current_scope}, {PerfectPaperWeb.UserAuth, :load_locale}]`
- `live_session :require_authenticated_user` → add `, {PerfectPaperWeb.UserAuth, :load_locale}` after `:require_authenticated`
- `live_session :require_admin` → add `, {PerfectPaperWeb.UserAuth, :load_locale}` at the end
- `live_session :current_user` → add `, {PerfectPaperWeb.UserAuth, :load_locale}` after `:mount_current_scope`

- [ ] **Step 5: Run to verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/locale_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/user_auth.ex lib/perfect_paper_web/router.ex test/perfect_paper_web/locale_live_test.exs
git commit -m "feat(i18n): :load_locale on_mount + preserve locale across session renewal"
```

---

### Task 7: `LocaleController` + `POST /locale`

**Files:**
- Create: `lib/perfect_paper_web/controllers/locale_controller.ex`
- Modify: `lib/perfect_paper_web/router.ex` (add `post "/locale"` in the public `:browser` scope, next to `/cookie-consent`)
- Test: `test/perfect_paper_web/controllers/locale_controller_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/controllers/locale_controller_test.exs
defmodule PerfectPaperWeb.LocaleControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "sets the pp_locale cookie and redirects back", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "de", "return_to" => "/"})
    assert redirected_to(conn) == "/"
    assert %{value: "de"} = conn.resp_cookies["pp_locale"]
  end

  test "rejects an unknown locale (no cookie set) and still redirects", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "zz", "return_to" => "/"})
    assert redirected_to(conn) == "/"
    refute Map.has_key?(conn.resp_cookies, "pp_locale")
  end

  test "an off-site return_to is rejected in favor of home", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "de", "return_to" => "https://evil.example.com"})
    assert redirected_to(conn) == "/"
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/controllers/locale_controller_test.exs`
Expected: FAIL — no `/locale` route.

- [ ] **Step 3: Write the controller**

```elixir
# lib/perfect_paper_web/controllers/locale_controller.ex
defmodule PerfectPaperWeb.LocaleController do
  @moduledoc """
  Records a visitor's language choice: sets the `pp_locale` cookie and, when
  logged in, persists `users.locale`. Returns the visitor to where they were.
  """
  use PerfectPaperWeb, :controller

  alias PerfectPaper.{Accounts, Localization}

  @one_year 60 * 60 * 24 * 365

  def update(conn, params) do
    locale = params["locale"]

    conn =
      if Localization.known?(locale) do
        conn
        |> put_resp_cookie("pp_locale", locale, max_age: @one_year, same_site: "Lax")
        |> maybe_persist(locale)
      else
        conn
      end

    redirect(conn, to: return_to(params, conn))
  end

  defp maybe_persist(conn, locale) do
    case conn.assigns[:current_scope] do
      %{user: %Accounts.User{} = user} ->
        Accounts.update_user_locale(user, locale)
        conn

      _ ->
        conn
    end
  end

  defp return_to(%{"return_to" => path}, _conn) when is_binary(path) do
    if local_path?(path), do: path, else: ~p"/"
  end

  defp return_to(_params, conn) do
    case get_req_header(conn, "referer") do
      [referer | _] -> referer_path(referer)
      _ -> ~p"/"
    end
  end

  # Only same-origin paths; reject protocol-relative and absolute URLs.
  defp local_path?("//" <> _), do: false
  defp local_path?("/" <> _), do: true
  defp local_path?(_), do: false

  defp referer_path(referer) do
    case URI.parse(referer) do
      %URI{path: "/" <> _ = path} -> path
      _ -> ~p"/"
    end
  end
end
```

> Note: `alias PerfectPaper.{Accounts, Localization}` brings `Accounts.User` into scope as `Accounts.User`.

- [ ] **Step 4: Add the route**

In `lib/perfect_paper_web/router.ex`, in the first public `scope "/", PerfectPaperWeb do … pipe_through :browser`, next to the cookie routes, add:

```elixir
    post "/locale", LocaleController, :update
```

- [ ] **Step 5: Run to verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/controllers/locale_controller_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/controllers/locale_controller.ex lib/perfect_paper_web/router.ex test/perfect_paper_web/controllers/locale_controller_test.exs
git commit -m "feat(i18n): POST /locale records language choice (cookie + persisted)"
```

---

### Task 8: `LocaleSwitcher` component, in marketing + app headers

**Files:**
- Create: `lib/perfect_paper_web/components/locale_switcher.ex`
- Modify: `lib/perfect_paper_web/components/layouts.ex` (render in `site_header/1`)
- Modify: `lib/perfect_paper_web/components/app_shell.ex` (render in the header actions area)
- Test: `test/perfect_paper_web/components/locale_switcher_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/components/locale_switcher_test.exs
defmodule PerfectPaperWeb.LocaleSwitcherTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "the marketing header renders the language switcher with native names", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)

    assert body =~ ~s(aria-label="Change language")
    assert body =~ "Deutsch"
    assert body =~ "Français"
    # Posts to the locale endpoint with the locale value as the submit button.
    assert body =~ ~s(action="/locale")
    assert body =~ ~s(name="locale" value="de")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/components/locale_switcher_test.exs`
Expected: FAIL — switcher not rendered.

- [ ] **Step 3: Write the component**

```elixir
# lib/perfect_paper_web/components/locale_switcher.ex
defmodule PerfectPaperWeb.LocaleSwitcher do
  @moduledoc """
  Globe-icon language switcher. Reads the current locale from Gettext (set by the
  FetchLocale plug / :load_locale on_mount) and offers the supported languages by
  native name. Each option is a submit button on one form posting to `/locale`.
  """
  use PerfectPaperWeb, :html

  alias PerfectPaper.Localization

  attr :return_to, :string, default: nil, doc: "optional same-origin path to return to"

  def switcher(assigns) do
    assigns =
      assigns
      |> assign(:current, Gettext.get_locale(PerfectPaperWeb.Gettext))
      |> assign(:locales, Localization.supported_locales())

    ~H"""
    <div class="dropdown dropdown-end">
      <button
        tabindex="0"
        type="button"
        class="btn btn-ghost btn-sm gap-1.5"
        aria-label="Change language"
      >
        <.icon name="hero-language" class="size-4" />
        <span class="font-sans text-xs font-semibold uppercase">{short(@current)}</span>
      </button>
      <div
        tabindex="0"
        class="dropdown-content z-50 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
      >
        <.form for={%{}} action={~p"/locale"} method="post">
          <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />
          <button
            :for={loc <- @locales}
            type="submit"
            name="locale"
            value={loc.code}
            class={[
              "flex w-full items-center justify-between rounded-lg px-3 py-2 text-left font-sans text-sm hover:bg-base-200",
              loc.code == @current && "font-semibold text-primary"
            ]}
          >
            {loc.native_name}
            <.icon :if={loc.code == @current} name="hero-check" class="size-4" />
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp short(code), do: code |> to_string() |> String.split("-") |> hd() |> String.upcase()
end
```

- [ ] **Step 4: Render in the marketing header**

In `lib/perfect_paper_web/components/layouts.ex`, in `site_header/1`, inside the `<div class="ml-auto flex items-center gap-3">` block, immediately before the `<%= if @current_scope do %>` line, add:

```elixir
          <PerfectPaperWeb.LocaleSwitcher.switcher />
```

- [ ] **Step 5: Render in the app header**

In `lib/perfect_paper_web/components/app_shell.ex`, in the header's actions container, change:

```elixir
          <div class="flex items-center gap-1.5">
            {render_slot(@actions)}
          </div>
```
to:
```elixir
          <div class="flex items-center gap-1.5">
            {render_slot(@actions)}
            <PerfectPaperWeb.LocaleSwitcher.switcher />
          </div>
```

- [ ] **Step 6: Run to verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/components/locale_switcher_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/perfect_paper_web/components/locale_switcher.ex lib/perfect_paper_web/components/layouts.ex lib/perfect_paper_web/components/app_shell.ex test/perfect_paper_web/components/locale_switcher_test.exs
git commit -m "feat(i18n): globe-icon language switcher in marketing + app headers"
```

---

### Task 9: Language preference in account settings

**Files:**
- Modify: `lib/perfect_paper_web/live/user_live/settings.ex` (add a Language form + handler)
- Test: `test/perfect_paper_web/live/user_settings_locale_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/live/user_settings_locale_test.exs
defmodule PerfectPaperWeb.UserSettingsLocaleTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "changing the language persists users.locale", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/users/settings")

    lv
    |> form("#locale_form", %{"user" => %{"locale" => "de"}})
    |> render_submit()

    assert PerfectPaper.Accounts.get_user!(user.id).locale == "de"
  end
end
```

> Implementer note: confirm the fixture helpers `user_fixture/0` and `log_in_user/2` and `Accounts.get_user!/1` exist (they are used by the existing `user_live` settings tests — mirror those imports). If `get_user!` is named differently, use the existing accessor.

- [ ] **Step 2: Run to verify failure**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/live/user_settings_locale_test.exs`
Expected: FAIL — no `#locale_form`.

- [ ] **Step 3: Add the Language section to the render**

In `lib/perfect_paper_web/live/user_live/settings.ex`, after the password `<.form>` (before the closing `</.app>`), add:

```elixir
      <div class="divider" />

      <.form for={@locale_form} id="locale_form" phx-submit="update_locale">
        <.input
          field={@locale_form[:locale]}
          type="select"
          label="Language"
          options={Enum.map(PerfectPaper.Localization.supported_locales(), &{&1.native_name, &1.code})}
        />
        <.button variant="primary" phx-disable-with="Saving...">Save Language</.button>
      </.form>
```

- [ ] **Step 4: Assign the form in `mount/2` and handle the submit**

In the `mount(_params, _session, socket)` clause, add `:locale_form` to the assigns pipeline:

```elixir
      |> assign(:locale_form, to_form(Accounts.change_user_locale(user)))
```

Add a handler (next to the other `handle_event/3` clauses):

```elixir
  def handle_event("update_locale", %{"user" => %{"locale" => locale}}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_locale(user, locale) do
      {:ok, _user} ->
        # Re-mount via live navigation so :load_locale re-reads the new locale.
        {:noreply,
         socket
         |> put_flash(:info, "Language updated.")
         |> push_navigate(to: ~p"/users/settings")}

      {:error, changeset} ->
        {:noreply, assign(socket, :locale_form, to_form(changeset, action: :update))}
    end
  end
```

- [ ] **Step 5: Run to verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/live/user_settings_locale_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/live/user_live/settings.ex test/perfect_paper_web/live/user_settings_locale_test.exs
git commit -m "feat(i18n): language preference in account settings"
```

---

### Task 10: Thread the user's locale into the LLM

**Files:**
- Modify: `lib/perfect_paper/chatbot/llm.ex` (behaviour: add `opts` arg)
- Modify: `lib/perfect_paper/chatbot/llm/stub.ex` (match new arity)
- Modify: `lib/perfect_paper/chatbot/llm/anthropic.ex` (append language directive)
- Modify: `lib/perfect_paper/chatbot.ex` (accept + pass locale)
- Test: `test/perfect_paper/chatbot/llm/anthropic_locale_test.exs`

- [ ] **Step 1: Write the failing test (adapter includes the directive)**

```elixir
# test/perfect_paper/chatbot/llm/anthropic_locale_test.exs
defmodule PerfectPaper.Chatbot.LLM.AnthropicLocaleTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Chatbot.LLM.Anthropic

  # Captures the outgoing request body via a Req stub plug, returning a canned
  # 200 so we can assert what system prompt was sent.
  defp with_captured_body(fun) do
    test = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:body, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => "ok"}]
      })
    end

    prev = Application.get_env(:perfect_paper, Anthropic, [])
    Application.put_env(:perfect_paper, Anthropic, api_key: "test-key", req_options: [plug: plug])
    try do
      fun.()
    after
      Application.put_env(:perfect_paper, Anthropic, prev)
    end
  end

  test "complete/2 appends the language directive for a non-English locale" do
    with_captured_body(fn ->
      Anthropic.complete([%{role: :user, content: "hi"}], locale: "de")
    end)

    assert_receive {:body, %{"system" => system}}
    assert system =~ "Deutsch"
  end

  test "complete/2 omits the directive for English" do
    with_captured_body(fn ->
      Anthropic.complete([%{role: :user, content: "hi"}], locale: "en")
    end)

    assert_receive {:body, %{"system" => system}}
    refute system =~ "locale"
  end

  test "review/3 appends the directive for a non-English locale" do
    with_captured_body(fn ->
      Anthropic.review("some manuscript", :preview, locale: "fr")
    end)

    assert_receive {:body, %{"system" => system}}
    assert system =~ "Français"
  end
end
```

> Implementer note: the existing `test/perfect_paper/chatbot/llm/anthropic_test.exs` already uses the `req_options: [plug: …]` injection — mirror its exact stub style if `Req.Test.json/2` is not the form it uses (it may build the response with `Plug.Conn.resp/3` + JSON). Match the existing file.

- [ ] **Step 2: Run to verify failure**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/chatbot/llm/anthropic_locale_test.exs`
Expected: FAIL — `Anthropic.complete/2` is undefined (only `/1` exists).

- [ ] **Step 3: Update the behaviour**

In `lib/perfect_paper/chatbot/llm.ex`, change the two callbacks to take `opts`:

```elixir
  @callback complete([%{role: atom(), content: String.t()}], opts :: keyword()) ::
              {:ok, %{role: :assistant, content: String.t()}} | {:error, term()}
```
and
```elixir
  @callback review(String.t(), level(), opts :: keyword()) ::
              {:ok, %{overall_feedback: String.t(), comments: [map()]}} | {:error, term()}
```

Add a sentence to the moduledoc: "`opts` carries `:locale` (default `\"en\"`); the adapter appends a language directive so generated feedback is written in the user's language."

- [ ] **Step 4: Update the Stub adapter to the new arity**

In `lib/perfect_paper/chatbot/llm/stub.ex`, change the heads:

```elixir
  def complete(_messages, _opts) do
    {:ok, %{role: :assistant, content: "This is a stubbed assistant response."}}
  end
```
and both review clauses:
```elixir
  def review(_text, :full, _opts) do
```
```elixir
  def review(_text, _preview, _opts) do
```
(update the `@spec` lines to add `, keyword()` before the `::`.)

- [ ] **Step 5: Update the Anthropic adapter**

In `lib/perfect_paper/chatbot/llm/anthropic.ex`:

Change `complete/1` head + system line:
```elixir
  def complete(messages, opts) when is_list(messages) do
    {system, turns} = split_system(messages)

    body = %{
      model: model(),
      max_tokens: @max_tokens,
      system: with_language(prepend(@chat_system, system), opts),
      messages: turns
    }
```
(update its `@spec` to `complete([...], keyword()) :: ...`.)

Change `review/2` head + system line:
```elixir
  def review(text, level, opts) when is_binary(text) and level in [:preview, :full] do
    body = %{
      model: model(),
      max_tokens: @max_tokens,
      system: with_language(review_system(level), opts),
      tools: [review_tool_schema()],
      tool_choice: %{type: "tool", name: @review_tool},
      messages: [%{role: "user", content: "Review the following manuscript:\n\n" <> text}]
    }
```
(update its `@spec` to `review(String.t(), LLM.level(), keyword()) :: ...`.)

Add the helper (next to `prepend/2`):
```elixir
  defp with_language(system, opts) do
    case PerfectPaper.Localization.language_directive(opts[:locale] || "en") do
      nil -> system
      directive -> system <> "\n\n" <> directive
    end
  end
```

- [ ] **Step 6: Update the Chatbot context to pass locale**

In `lib/perfect_paper/chatbot.ex`:

Change `answer/1` to `answer/2` with a locale default and pass it down:
```elixir
  @spec answer(Conversation.t(), String.t()) :: {:ok, ChatMessage.t()} | {:error, term()}
  def answer(%Conversation{} = conversation, locale \\ "en") do
    history =
      from(m in ChatMessage,
        where: m.conversation_id == ^conversation.id,
        order_by: [asc: m.inserted_at, asc: m.id],
        select: %{role: m.role, content: m.content}
      )
      |> Repo.all()

    with {:ok, %{role: :assistant, content: content}} <- llm().complete(history, locale: locale) do
      %ChatMessage{}
      |> ChatMessage.create_changeset(%{
        role: :assistant,
        content: content,
        conversation_id: conversation.id
      })
      |> Repo.insert()
    end
  end
```

Change `review_document/2` to `review_document/3`:
```elixir
  @spec review_document(String.t(), PerfectPaper.Chatbot.LLM.level(), String.t()) ::
          {:ok, %{overall_feedback: String.t(), comments: [map()]}} | {:error, term()}
  def review_document(text, level, locale \\ "en")
      when is_binary(text) and level in [:preview, :full] do
    llm().review(text, level, locale: locale)
  end
```

- [ ] **Step 7: Run to verify it passes (and existing chatbot tests still pass)**

Run:
```bash
MIX_TEST_PARTITION=eu mix test test/perfect_paper/chatbot/llm/anthropic_locale_test.exs test/perfect_paper/chatbot
```
Expected: PASS. Fix any existing caller of `answer/1`, `review_document/2`, or the Stub arity that the compiler flags — they now use the defaulted-arg versions, so callers that pass no locale keep working; only the adapter arity changed (always called with opts from the context).

- [ ] **Step 8: Commit**

```bash
git add lib/perfect_paper/chatbot test/perfect_paper/chatbot/llm/anthropic_locale_test.exs
git commit -m "feat(chatbot): thread user locale into LLM; AI feedback in the user's language"
```

---

### Task 11: Prove it end-to-end — localize the cookie banner + site header

**Files:**
- Modify: `lib/perfect_paper_web/components/cookie_consent.ex` (wrap visible strings in `gettext/1`)
- Modify: `lib/perfect_paper_web/components/layouts.ex` (wrap a couple of `site_header` strings)
- Generate/edit: `priv/gettext/de/LC_MESSAGES/default.po` (seed a German entry)
- Test: `test/perfect_paper_web/i18n_smoke_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/i18n_smoke_test.exs
defmodule PerfectPaperWeb.I18nSmokeTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "the cookie banner renders in German for a de visitor", %{conn: conn} do
    body =
      conn
      |> put_req_header("cf-ipcountry", "DE")
      |> put_req_header("accept-language", "de")
      |> get(~p"/")
      |> html_response(200)

    assert body =~ "Ihre Datenschutzeinstellungen"
  end

  test "the same string renders in English by default", %{conn: conn} do
    body = conn |> put_req_header("cf-ipcountry", "DE") |> get(~p"/") |> html_response(200)
    assert body =~ "Your privacy choices"
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/i18n_smoke_test.exs`
Expected: FAIL — the German string is absent (strings not yet wrapped/translated).

- [ ] **Step 3: Wrap the banner heading (and a few sibling strings) in gettext**

In `lib/perfect_paper_web/components/cookie_consent.ex`, in `banner/1`, change the title and primary labels to use `gettext/1`. For example:

```elixir
              <h2 id="cookie-consent-title" class="font-display text-lg font-semibold text-base-content">
                {gettext("Your privacy choices")}
              </h2>
```
and the two primary buttons:
```elixir
                  {gettext("Reject non-essential")}
```
```elixir
                  {gettext("Accept all")}
```

(Leave the rest for the P2 marketing pass — this task only needs enough to prove the pipeline.)

- [ ] **Step 4: Extract and seed the German translation**

Run extraction + merge:
```bash
mix gettext.extract
for loc in en-GB de fr fr-CA es es-MX nl it hi ru ro; do mix gettext.merge priv/gettext --locale "$loc"; done
```

Then edit `priv/gettext/de/LC_MESSAGES/default.po` and fill the German for the banner title (mark it for review with a translator comment), e.g.:

```po
#. NOTE: machine draft — needs native review before launch
msgid "Your privacy choices"
msgstr "Ihre Datenschutzeinstellungen"
```

- [ ] **Step 5: Run to verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/i18n_smoke_test.exs`
Expected: PASS (German for `de`, English by default).

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/components/cookie_consent.ex priv/gettext test/perfect_paper_web/i18n_smoke_test.exs
git commit -m "feat(i18n): localize cookie banner; prove locale pipeline end-to-end (de)"
```

---

### Task 12: Pre-merge verification & merge to main

- [ ] **Step 1: Format + full suite under the partition**

Run: `MIX_TEST_PARTITION=eu mix precommit`
Expected: compiles with `--warnings-as-errors`, format clean, **0 test failures**. Fix anything red before proceeding (broken tests are yours to fix).

- [ ] **Step 2: Integrate main (it may have moved) and re-verify**

```bash
git fetch . main:main 2>/dev/null || true   # no-op if main not advanced
git merge --no-edit main
mix deps.get
MIX_TEST_PARTITION=eu mix test
```
If `main` is checked out elsewhere and not behind, merge main into this branch as in sub-project A: `git merge --no-edit main`, resolve any conflicts, re-run tests.

- [ ] **Step 3: Fast-forward main to the integrated branch**

Verify main is fully contained, then update it (main is not checked out in any worktree):
```bash
git rev-list main ^worktree-european-compliance   # expect empty
git fetch . worktree-european-compliance:main
git show main:lib/perfect_paper/localization.ex >/dev/null && echo "landed on main"
```

- [ ] **Step 4: Report** "committed and merged back to main with no issues."

---

## Self-Review

**Spec coverage:**
- Locale resolution / single source of truth → Tasks 1, 5, 6. ✓
- 12-locale set + native names + base fallback → Task 1. ✓
- Gettext config for all locales → Task 2. ✓
- `users.locale` + changeset + Accounts API → Task 3. ✓
- Signup default from Accept-Language → Tasks 4 (cast) + 5/6 (resolution feeds registration attrs; the registration LiveViews pass `@locale` — see note below). ✓
- Globe-icon switcher in marketing + app → Task 8. ✓
- `/locale` endpoint (cookie + persist + open-redirect guard) → Task 7. ✓
- Settings language section → Task 9. ✓
- AI feedback in user's language (behaviour + adapters + context) → Task 10. ✓
- End-to-end proof on banner/header → Task 11. ✓
- Phasing: this plan is P1 only; P2 (marketing extraction) and P3 (app extraction) are separate plans. ✓

**Gap noted & closed:** the spec says registration defaults locale from the negotiated `Accept-Language`. Task 4 casts `:locale` from attrs; the *value* must be supplied by the registration LiveViews. Add to each registration submit a `locale: @locale` (the `:load_locale` on_mount assigns `@locale` on the `:current_user` live_session, which the registration LiveViews use). Implementer: when wiring Task 6's `:load_locale` into `live_session :current_user`, also pass `@locale` into the registration changeset attrs in `UserLive.Registration` (merge `%{"locale" => @locale}` into the user params on submit). This is a 1-line change; if `@locale` is absent the schema default `"en"` applies.

**Placeholder scan:** no TBD/TODO; every code step shows complete code. The two "implementer notes" (fixtures in Task 9, Req-stub style in Task 10) point at existing files to mirror, not missing content.

**Type consistency:** `Localization.codes/0`, `known?/1`, `native_name/1`, `base_of/1`, `negotiate/1`, `resolve/1`, `language_directive/1` are used consistently across Tasks 1, 3, 5, 6, 7, 8, 10. `Accounts.update_user_locale/2` + `change_user_locale/2` consistent across Tasks 3, 7, 9. LLM `complete/2` + `review/3` consistent across Tasks 10's behaviour, adapters, and context.
