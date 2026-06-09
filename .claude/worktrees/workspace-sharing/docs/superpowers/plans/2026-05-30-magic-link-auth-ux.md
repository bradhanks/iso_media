# Magic-link Auth UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `/users/register` and `/users/log-in` into a polished, magic-link-first experience with an in-place "Check your email" state and rate-limited, anti-enumeration submits.

**Architecture:** Add two web-layer infrastructure modules — a Hammer-backed `RateLimit` wrapper and a `ClientMetadata` IP reader — then rewrite the two auth LiveViews to use them. No context API or DB changes; the magic-link mechanism (`Accounts.register_user/1` → `deliver_login_instructions/2`) already exists. Registration stays email-only (passwords are set in Settings).

**Tech Stack:** Elixir/Phoenix 1.8, LiveView, Hammer 7 (ETS backend), ExUnit (`DataCase`/`ConnCase`), daisyUI `paper` theme.

**Spec:** `docs/superpowers/specs/2026-05-30-magic-link-auth-ux-design.md`

---

## File Structure

- Create `lib/perfect_paper_web/rate_limit.ex` — Hammer wrapper + supervised ETS store. One job: "is this key over its limit?"
- Create `lib/perfect_paper_web/client_metadata.ex` — extract client IP from a LiveView socket; pure parse helper for testability.
- Modify `mix.exs` — add `{:hammer, "~> 7.0"}`.
- Modify `lib/perfect_paper/application.ex` — supervise the rate-limit ETS store.
- Modify `lib/perfect_paper_web/endpoint.ex` — add `:peer_data`, `:x_headers` to socket `connect_info`.
- Rewrite `lib/perfect_paper_web/live/user_live/registration.ex` — magic-link-first + check-email state.
- Rewrite `lib/perfect_paper_web/live/user_live/login.ex` — magic-link-first + password toggle + check-email state.
- Update tests: `test/perfect_paper_web/rate_limit_test.exs`, `test/perfect_paper_web/client_metadata_test.exs`, `test/perfect_paper_web/live/user_live/registration_test.exs`, `test/perfect_paper_web/live/user_live/login_test.exs`.

---

## Task 1: Hammer dependency + RateLimit store

**Files:**
- Modify: `mix.exs`
- Modify: `lib/perfect_paper/application.ex:10` (children list)
- Create: `lib/perfect_paper_web/rate_limit.ex`
- Test: `test/perfect_paper_web/rate_limit_test.exs`

- [ ] **Step 1: Add the Hammer dependency**

In `mix.exs`, inside `defp deps do [ ... ]`, add this line (alongside the other deps):

```elixir
{:hammer, "~> 7.0"},
```

- [ ] **Step 2: Fetch the dependency**

Run: `mix deps.get`
Expected: resolves and installs `hammer` (and its dep `ex_rated`/`:telemetry` as applicable). No errors.

- [ ] **Step 3: Write the failing test**

Create `test/perfect_paper_web/rate_limit_test.exs`:

```elixir
defmodule PerfectPaperWeb.RateLimitTest do
  use ExUnit.Case, async: true

  alias PerfectPaperWeb.RateLimit

  # Unique key per test run so buckets never collide across runs.
  defp key, do: "test:#{System.unique_integer([:positive])}"

  test "allows calls up to the limit, then blocks" do
    k = key()
    assert RateLimit.check(k, 60_000, 3) == :ok
    assert RateLimit.check(k, 60_000, 3) == :ok
    assert RateLimit.check(k, 60_000, 3) == :ok
    assert RateLimit.check(k, 60_000, 3) == :rate_limited
  end

  test "independent keys have independent buckets" do
    a = key()
    b = key()
    assert RateLimit.check(a, 60_000, 1) == :ok
    assert RateLimit.check(a, 60_000, 1) == :rate_limited
    assert RateLimit.check(b, 60_000, 1) == :ok
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `mix test test/perfect_paper_web/rate_limit_test.exs`
Expected: FAIL — `PerfectPaperWeb.RateLimit` is undefined / `RateLimit.Store` not started.

- [ ] **Step 5: Create the RateLimit module + store**

Create `lib/perfect_paper_web/rate_limit.ex`:

```elixir
defmodule PerfectPaperWeb.RateLimit do
  @moduledoc """
  Web-layer rate limiting for auth endpoints.

  Thin anti-corruption wrapper over Hammer: callers pass a bucket key, a window
  in milliseconds, and a max count, and get back `:ok` or `:rate_limited` —
  never Hammer's internal return shape. Backed by a supervised ETS store
  (`#{__MODULE__}.Store`).
  """

  defmodule Store do
    @moduledoc false
    use Hammer, backend: :ets
  end

  @doc """
  Records a hit against `key` and reports whether it is within `limit` for the
  rolling `window_ms` window.
  """
  @spec check(String.t(), pos_integer(), pos_integer()) :: :ok | :rate_limited
  def check(key, window_ms, limit)
      when is_binary(key) and is_integer(window_ms) and window_ms > 0 and
             is_integer(limit) and limit > 0 do
    case Store.hit(key, window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> :rate_limited
    end
  end
end
```

- [ ] **Step 6: Supervise the store**

In `lib/perfect_paper/application.ex`, add `PerfectPaperWeb.RateLimit.Store` to the `children` list (near the top, before the endpoint). The list becomes, for example:

```elixir
children = [
  PerfectPaperWeb.Telemetry,
  PerfectPaper.Repo,
  {DNSCluster, query: Application.get_env(:perfect_paper, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: PerfectPaper.PubSub},
  {PerfectPaperWeb.RateLimit.Store, [clean_period: :timer.minutes(1)]},
  PerfectPaperWeb.Endpoint
]
```

(Match the existing children already present; only **add** the `RateLimit.Store` line. Keep the others exactly as they are.)

- [ ] **Step 7: Run the test to verify it passes**

Run: `mix test test/perfect_paper_web/rate_limit_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 8: Commit**

```bash
git add mix.exs mix.lock lib/perfect_paper_web/rate_limit.ex lib/perfect_paper/application.ex test/perfect_paper_web/rate_limit_test.exs
git commit -m "feat(auth): add Hammer-backed RateLimit web helper"
```

---

## Task 2: ClientMetadata (client IP from socket)

**Files:**
- Create: `lib/perfect_paper_web/client_metadata.ex`
- Modify: `lib/perfect_paper_web/endpoint.ex:14-16`
- Test: `test/perfect_paper_web/client_metadata_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/perfect_paper_web/client_metadata_test.exs`. We test the pure parser (the socket-reading wrapper is exercised by the LiveView tests):

```elixir
defmodule PerfectPaperWeb.ClientMetadataTest do
  use ExUnit.Case, async: true

  alias PerfectPaperWeb.ClientMetadata

  test "prefers the first hop of x-forwarded-for" do
    info = %{x_headers: [{"x-forwarded-for", "203.0.113.7, 70.41.3.18"}]}
    assert ClientMetadata.ip_from_connect_info(info) == "203.0.113.7"
  end

  test "falls back to peer_data address when no forwarded header" do
    info = %{peer_data: %{address: {127, 0, 0, 1}}}
    assert ClientMetadata.ip_from_connect_info(info) == "127.0.0.1"
  end

  test "returns nil when no metadata is present" do
    assert ClientMetadata.ip_from_connect_info(%{}) == nil
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/perfect_paper_web/client_metadata_test.exs`
Expected: FAIL — `PerfectPaperWeb.ClientMetadata` is undefined.

- [ ] **Step 3: Create the ClientMetadata module**

Create `lib/perfect_paper_web/client_metadata.ex`:

```elixir
defmodule PerfectPaperWeb.ClientMetadata do
  @moduledoc """
  Extracts request metadata (currently the client IP) from a connected
  LiveView socket. Returns `nil` when metadata is unavailable (e.g. the static
  render before the socket connects), so callers fall back to a shared bucket:

      ip = ClientMetadata.client_ip(socket) || "unknown"
  """

  @doc "Client IP for a connected socket, or `nil` if unavailable."
  @spec client_ip(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def client_ip(socket) do
    socket
    |> Phoenix.LiveView.get_connect_info(:x_headers)
    |> case do
      nil -> %{}
      headers -> %{x_headers: headers}
    end
    |> Map.put(:peer_data, Phoenix.LiveView.get_connect_info(socket, :peer_data))
    |> ip_from_connect_info()
  end

  @doc """
  Pure resolution of an IP string from connect-info fields. Prefers the first
  hop of `x-forwarded-for`, then the `peer_data` address, else `nil`.
  """
  @spec ip_from_connect_info(map()) :: String.t() | nil
  def ip_from_connect_info(info) when is_map(info) do
    forwarded_ip(info[:x_headers]) || peer_ip(info[:peer_data])
  end

  defp forwarded_ip(headers) when is_list(headers) do
    case List.keyfind(headers, "x-forwarded-for", 0) do
      {_k, value} ->
        value |> String.split(",") |> List.first() |> String.trim() |> presence()

      _ ->
        nil
    end
  end

  defp forwarded_ip(_), do: nil

  defp peer_ip(%{address: address}) when is_tuple(address) do
    address |> :inet.ntoa() |> to_string() |> presence()
  end

  defp peer_ip(_), do: nil

  defp presence(""), do: nil
  defp presence(string), do: string
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/perfect_paper_web/client_metadata_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Expose IP metadata on the LiveView socket**

In `lib/perfect_paper_web/endpoint.ex`, update the `/live` socket's `connect_info` (lines 14-16) to include `:peer_data` and `:x_headers`:

```elixir
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options, :peer_data, :x_headers]],
    longpoll: [connect_info: [session: @session_options, :peer_data, :x_headers]]
```

- [ ] **Step 6: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean, no warnings.

- [ ] **Step 7: Commit**

```bash
git add lib/perfect_paper_web/client_metadata.ex lib/perfect_paper_web/endpoint.ex test/perfect_paper_web/client_metadata_test.exs
git commit -m "feat(auth): add ClientMetadata IP reader + socket connect_info"
```

---

## Task 3: Rewrite the Registration LiveView

**Files:**
- Modify: `lib/perfect_paper_web/live/user_live/registration.ex` (full rewrite)
- Test: `test/perfect_paper_web/live/user_live/registration_test.exs` (rewrite changed cases)

**Behavior contract:**
- Magic-link-first email form (`#registration_form`), primary CTA "Send magic link".
- On submit: rate-limit per-IP (5/60s) and per-email (5/3600s). On allow, register the email (or, if it already exists, send the existing user a link) and deliver instructions. Always transition to the in-place check-email state. On throttle, show the same state without sending.
- Anti-enumeration: identical UI/copy whether the email is new, existing, or throttled.
- Live `validate` still surfaces email-format errors inline before submit.

- [ ] **Step 1: Write the failing tests**

Replace the body of `test/perfect_paper_web/live/user_live/registration_test.exs` with:

```elixir
defmodule PerfectPaperWeb.UserLive.RegistrationTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Accounts

  describe "Registration page" do
    test "renders the magic-link registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Send magic link"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid email format", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "new email: creates user and shows check-email state", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = unique_user_email()

      html =
        lv
        |> form("#registration_form", user: %{"email" => email})
        |> render_submit()

      assert html =~ "Check your email"
      assert html =~ email
      assert Accounts.get_user_by_email(email)
    end

    test "existing email: same check-email state, no enumeration", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      html =
        lv
        |> form("#registration_form", user: %{"email" => user.email})
        |> render_submit()

      assert html =~ "Check your email"
      refute html =~ "has already been taken"
    end

    test "rate limited: shows check-email state without a sixth send", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      for _ <- 1..6 do
        lv
        |> form("#registration_form", user: %{"email" => unique_user_email()})
        |> render_submit()
      end

      html = render(lv)
      assert html =~ "Check your email"
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/perfect_paper_web/live/user_live/registration_test.exs`
Expected: FAIL — current page renders "Register"/"Create an account" and redirects, so "Send magic link"/"Check your email" assertions fail.

- [ ] **Step 3: Rewrite the Registration LiveView**

Replace the full contents of `lib/perfect_paper_web/live/user_live/registration.ex`:

```elixir
defmodule PerfectPaperWeb.UserLive.Registration do
  @moduledoc """
  Magic-link-first registration. Captures an email, sends a sign-in link, and
  shows an in-place "Check your email" state. Submits are rate limited and
  anti-enumeration: a new, existing, or throttled email all look identical.
  Passwords are set later in Settings (registration is email-only).
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.Accounts
  alias PerfectPaper.Accounts.User
  alias PerfectPaperWeb.{ClientMetadata, RateLimit}

  @ip_window_ms 60_000
  @ip_limit 5
  @email_window_ms 60 * 60 * 1000
  @email_limit 5

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6">
        <div :if={@check_email} class="text-center space-y-4">
          <div class="flex justify-center">
            <.icon name="hero-envelope" class="size-12 text-primary" />
          </div>
          <.header>
            Check your email
            <:subtitle>
              If an account exists for {@sent_to}, you'll receive a sign-in link shortly.
            </:subtitle>
          </.header>
          <p class="ds-p text-base-content/60">
            Didn't get it?
            <button type="button" phx-click="resend" class="link link-primary">Resend</button>
            or
            <.link navigate={~p"/users/log-in"} class="link link-primary">log in</.link>.
          </p>
        </div>

        <div :if={!@check_email}>
          <div class="text-center">
            <.header>
              Create your account
              <:subtitle>
                Already registered?
                <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                  Log in
                </.link>
                to your account now.
              </:subtitle>
            </.header>
          </div>

          <.form
            for={@form}
            id="registration_form"
            phx-submit="save"
            phx-change="validate"
            class="space-y-4 mt-6"
          >
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button phx-disable-with="Sending link..." class="btn btn-primary w-full">
              Send magic link <span aria-hidden="true">→</span>
            </.button>
          </.form>

          <p class="ds-p text-center text-xs text-base-content/50 mt-4">
            Prefer a password? You can set one in Settings after your first sign-in.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: PerfectPaperWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign(check_email: false, sent_to: nil)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"user" => %{"email" => email} = user_params}, socket) do
    email = String.trim(email)

    if rate_limited?(socket, email) do
      {:noreply, to_check_email(socket, email)}
    else
      _ = deliver_signup_link(user_params)
      {:noreply, to_check_email(socket, email)}
    end
  end

  def handle_event("resend", _params, socket) do
    email = socket.assigns.sent_to

    if email && !rate_limited?(socket, email) do
      _ = deliver_signup_link(%{"email" => email})
    end

    {:noreply, put_flash(socket, :info, "If an account exists, we've re-sent the link.")}
  end

  # Register a brand-new email, or — for an address that already exists — send
  # that existing user a link. Either branch ends in the same outward state, so
  # registration cannot be used to probe which emails exist.
  defp deliver_signup_link(%{"email" => email} = params) do
    case Accounts.register_user(params) do
      {:ok, user} ->
        Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

      {:error, _changeset} ->
        case Accounts.get_user_by_email(String.trim(email)) do
          %User{} = user ->
            Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

          nil ->
            :ok
        end
    end
  end

  defp rate_limited?(socket, email) do
    ip = ClientMetadata.client_ip(socket) || "unknown"
    email_key = String.downcase(email)

    RateLimit.check("auth_submit:ip:#{ip}", @ip_window_ms, @ip_limit) == :rate_limited or
      RateLimit.check("auth_submit:email:#{email_key}", @email_window_ms, @email_limit) ==
        :rate_limited
  end

  defp to_check_email(socket, email) do
    assign(socket, check_email: true, sent_to: email)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/perfect_paper_web/live/user_live/registration_test.exs`
Expected: PASS (all Registration tests).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/live/user_live/registration.ex test/perfect_paper_web/live/user_live/registration_test.exs
git commit -m "feat(auth): magic-link-first registration with check-email state"
```

---

## Task 4: Rewrite the Login LiveView

**Files:**
- Modify: `lib/perfect_paper_web/live/user_live/login.ex` (full rewrite)
- Test: `test/perfect_paper_web/live/user_live/login_test.exs` (add toggle + check-email cases; keep existing password-login cases working)

**Behavior contract:**
- Default magic-link mode: email form (`#login_form_magic`), CTA "Send magic link". Submit is rate-limited; existing users get a link; always shows the check-email state with anti-enumeration copy.
- "Use a password instead" toggle reveals the password form (`#login_form_password`) which posts to `UserSessionController` via `phx-trigger-action` exactly as today.
- Local-mail-adapter info alert preserved.

- [ ] **Step 1: Inspect the existing login tests**

Run: `mix test test/perfect_paper_web/live/user_live/login_test.exs`
Expected: current tests PASS against the old two-form page. Read the file to see which selectors/copy they assert (`#login_form_magic`, `#login_form_password`, "Log in with email", password submit). Preserve element IDs `#login_form_magic` and `#login_form_password` in the rewrite so existing password/magic tests keep working.

- [ ] **Step 2: Add the new failing tests**

Append these tests inside the top-level `describe` (or a new `describe "magic link UX"`) block in `test/perfect_paper_web/live/user_live/login_test.exs`:

```elixir
  describe "magic link UX" do
    test "defaults to magic-link mode and can toggle to password", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Send magic link"

      shown =
        lv
        |> element("button", "Use a password instead")
        |> render_click()

      assert shown =~ "Password"
    end

    test "magic-link submit for an existing user shows check-email state", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      html =
        lv
        |> form("#login_form_magic", user: %{email: user.email})
        |> render_submit()

      assert html =~ "Check your email"
      assert html =~ user.email
    end

    test "magic-link submit for an unknown email shows the same state", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      html =
        lv
        |> form("#login_form_magic", user: %{email: "nobody@example.com"})
        |> render_submit()

      assert html =~ "Check your email"
      refute html =~ "Invalid"
    end
  end
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `mix test test/perfect_paper_web/live/user_live/login_test.exs`
Expected: the three new tests FAIL (no toggle button, magic submit currently redirects with a flash rather than rendering a check-email state).

- [ ] **Step 4: Rewrite the Login LiveView**

Replace the full contents of `lib/perfect_paper_web/live/user_live/login.ex`:

```elixir
defmodule PerfectPaperWeb.UserLive.Login do
  @moduledoc """
  Magic-link-first login with a "use a password instead" toggle. The magic-link
  path is rate limited and anti-enumeration (existing and unknown emails look
  identical) and shows an in-place "Check your email" state. The password path
  posts to `UserSessionController` unchanged.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.Accounts
  alias PerfectPaperWeb.{ClientMetadata, RateLimit}

  @ip_window_ms 60_000
  @ip_limit 5
  @email_window_ms 60 * 60 * 1000
  @email_limit 5

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6">
        <div :if={@check_email} class="text-center space-y-4">
          <div class="flex justify-center">
            <.icon name="hero-envelope" class="size-12 text-primary" />
          </div>
          <.header>
            Check your email
            <:subtitle>
              If an account exists for {@sent_to}, you'll receive a sign-in link shortly.
            </:subtitle>
          </.header>
        </div>

        <div :if={!@check_email} class="space-y-4">
          <div class="text-center">
            <.header>
              <p>Log in</p>
              <:subtitle>
                <%= if @current_scope do %>
                  You need to reauthenticate to perform sensitive actions on your account.
                <% else %>
                  Don't have an account? <.link
                    navigate={~p"/users/register"}
                    class="font-semibold text-brand hover:underline"
                    phx-no-format
                  >Sign up</.link> for an account now.
                <% end %>
              </:subtitle>
            </.header>
          </div>

          <div :if={local_mail_adapter?()} class="alert alert-info">
            <.icon name="hero-information-circle" class="size-6 shrink-0" />
            <div>
              <p>You are running the local mail adapter.</p>
              <p>
                To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
              </p>
            </div>
          </div>

          <%!-- Magic-link form (default) --%>
          <.form
            :let={f}
            :if={!@password_mode}
            for={@form}
            id="login_form_magic"
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button phx-disable-with="Sending link..." class="btn btn-primary w-full">
              Send magic link <span aria-hidden="true">→</span>
            </.button>
          </.form>

          <%!-- Password form (revealed by toggle) --%>
          <.form
            :let={f}
            :if={@password_mode}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              spellcheck="false"
            />
            <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
              Log in and stay logged in <span aria-hidden="true">→</span>
            </.button>
            <.button class="btn btn-primary btn-soft w-full mt-2">
              Log in only this time
            </.button>
          </.form>

          <div class="text-center">
            <button type="button" phx-click="toggle_password" class="link link-primary text-sm">
              {if @password_mode, do: "Use a magic link instead", else: "Use a password instead"}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       password_mode: false,
       check_email: false,
       sent_to: nil
     )}
  end

  @impl true
  def handle_event("toggle_password", _params, socket) do
    {:noreply, assign(socket, :password_mode, !socket.assigns.password_mode)}
  end

  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    email = String.trim(email)

    unless rate_limited?(socket, email) do
      if user = Accounts.get_user_by_email(email) do
        Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
      end
    end

    {:noreply, assign(socket, check_email: true, sent_to: email)}
  end

  defp rate_limited?(socket, email) do
    ip = ClientMetadata.client_ip(socket) || "unknown"
    email_key = String.downcase(email)

    RateLimit.check("auth_submit:ip:#{ip}", @ip_window_ms, @ip_limit) == :rate_limited or
      RateLimit.check("auth_submit:email:#{email_key}", @email_window_ms, @email_limit) ==
        :rate_limited
  end

  defp local_mail_adapter? do
    Application.get_env(:perfect_paper, PerfectPaper.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
```

- [ ] **Step 5: Run the login tests to verify they pass**

Run: `mix test test/perfect_paper_web/live/user_live/login_test.exs`
Expected: PASS. If a pre-existing test asserted the old magic-link redirect-with-flash (e.g. "If your email is in our system…" via `follow_redirect`), update that test to assert the new in-place check-email state instead (`assert html =~ "Check your email"`). Fix any such test — do not leave it red.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/live/user_live/login.ex test/perfect_paper_web/live/user_live/login_test.exs
git commit -m "feat(auth): magic-link-first login with password toggle + check-email state"
```

---

## Task 5: Pre-merge verification and merge

**Files:** none (verification + git)

- [ ] **Step 1: Run the full auth-related suite**

Run: `mix test test/perfect_paper_web/live/user_live/ test/perfect_paper_web/rate_limit_test.exs test/perfect_paper_web/client_metadata_test.exs`
Expected: all PASS.

- [ ] **Step 2: Run precommit**

Run: `mix precommit`
Expected: compile (warnings-as-errors) clean, `deps.unlock --unused` clean, format clean, full test suite PASS. Fix anything red — including tests elsewhere that referenced the old auth copy/flow.

- [ ] **Step 3: Manual smoke (optional but recommended)**

Run: `mix phx.server`, visit `/users/register`, submit an email, confirm the "Check your email" panel renders and the link appears at `/dev/mailbox`. Visit `/users/log-in`, toggle to password and back.

- [ ] **Step 4: Merge back to main**

```bash
git checkout main
git merge --no-ff feature/magic-link-auth-ux -m "Merge: magic-link-first auth UX (register + login)"
```

Expected: clean merge. Report: "committed and merged back to main with no issues."

---

## Notes for the implementer

- **Anti-enumeration is the whole point of the duplicate-email handling.** Never surface "has already been taken" on the register submit path; live `validate` uses `validate_unique: false` so that error never appears inline either.
- **Element IDs matter:** keep `#registration_form`, `#login_form_magic`, `#login_form_password` — existing tests and any JS hooks key off them.
- **Rate-limit buckets are process-global ETS.** In `async: true` tests, use unique emails per submit (as the tests do) so one test's bucket doesn't throttle another's. The "rate limited" test deliberately reuses the IP bucket by firing 6 submits in one LiveView.
- **`Phoenix.LiveView.get_connect_info/2`** returns `nil` in the static (disconnected) mount and in tests without configured peer data — `ClientMetadata.client_ip/1` then yields `nil` and callers use `"unknown"`. That's expected and safe.
