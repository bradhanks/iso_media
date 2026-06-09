# Admin "comp credits" page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an operator-only LiveView at `/admin/credits` that grants goodwill ("comp") credits to an account by email, with attribution recorded in the ledger.

**Architecture:** A comp is a positive `credit_event` (no new table). A new `Credits.comp_account/4` context function records the grant plus attribution in `metadata`. The page is gated by a config email allowlist via a new `UserAuth.require_admin` on_mount hook. The LiveView looks up a user, shows their balance, and submits grants — validating the form with a schemaless `Ecto.Changeset`.

**Tech Stack:** Elixir/Phoenix 1.8, LiveView, Ecto (binary_id), daisyUI. Branch `feat/admin-comp-credits` is already checked out.

---

## File Structure

- **Create** `lib/perfect_paper_web/live/admin_live/credits.ex` — the LiveView module (mount, lookup/grant events, schemaless grant changeset).
- **Create** `lib/perfect_paper_web/live/admin_live/credits.html.heex` — collocated template.
- **Create** `test/perfect_paper_web/live/admin_live/credits_test.exs` — LiveView tests (access control + granting).
- **Modify** `lib/perfect_paper/credits.ex` — add `comp_account/4`.
- **Modify** `test/perfect_paper/credits_test.exs` — add `comp_account/4` tests.
- **Modify** `lib/perfect_paper_web/user_auth.ex` — add `admin_emails/0` + `on_mount(:require_admin, ...)`.
- **Modify** `lib/perfect_paper_web/router.ex` — add the `/admin` live_session + route.
- **Modify** `config/config.exs` — default `:admin_emails` to `[]`.
- **Modify** `config/test.exs` — set a known admin email for tests.
- **Modify** `config/runtime.exs` — read `ADMIN_EMAILS` from the environment in prod.

---

## Task 1: `Credits.comp_account/4` context function

**Files:**
- Modify: `lib/perfect_paper/credits.ex`
- Test: `test/perfect_paper/credits_test.exs`

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to `test/perfect_paper/credits_test.exs` (after the `grant/3` block). It uses the already-imported `user_fixture` and the existing `alias PerfectPaper.Credits`:

```elixir
  describe "comp_account/4" do
    test "increases the balance and records attribution metadata" do
      user = user_fixture()
      admin = user_fixture()

      assert {:ok, event} =
               Credits.comp_account(user.id, 25, "sorry for the outage", admin.id)

      assert event.amount == 25
      assert event.reason == "sorry for the outage"
      assert event.metadata["kind"] == "comp"
      assert event.metadata["granted_by"] == admin.id
      assert Credits.balance(user.id) == 25
    end

    test "rejects a non-positive amount via the guard" do
      user = user_fixture()
      admin = user_fixture()

      assert_raise FunctionClauseError, fn ->
        Credits.comp_account(user.id, 0, "nope", admin.id)
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/perfect_paper/credits_test.exs`
Expected: FAIL — `function PerfectPaper.Credits.comp_account/4 is undefined`.

- [ ] **Step 3: Implement `comp_account/4`**

In `lib/perfect_paper/credits.ex`, add this function inside the "Granting credits" section, directly after `grant/3`:

```elixir
  @doc """
  Grants goodwill ("comp") credits to a user and records who issued the grant.

  Records a positive ledger entry whose `reason` is the operator's note and whose
  `metadata` captures attribution: `%{"kind" => "comp", "granted_by" => granted_by_id}`.
  """
  @spec comp_account(Ecto.UUID.t(), pos_integer(), String.t(), Ecto.UUID.t()) ::
          {:ok, CreditEvent.t()} | {:error, Ecto.Changeset.t()}
  def comp_account(user_id, amount, reason, granted_by_id)
      when is_integer(amount) and amount > 0 do
    %CreditEvent{}
    |> CreditEvent.create_changeset(%{
      user_id: user_id,
      amount: amount,
      reason: reason,
      metadata: %{"kind" => "comp", "granted_by" => granted_by_id}
    })
    |> Repo.insert()
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/perfect_paper/credits_test.exs`
Expected: PASS (all, including the existing ones).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/credits.ex test/perfect_paper/credits_test.exs
git commit -m "feat(credits): add comp_account/4 for attributed goodwill grants"
```

---

## Task 2: Admin email allowlist config

**Files:**
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`

No test for this task on its own — it is configuration consumed by Task 3 and exercised by Task 4's tests.

- [ ] **Step 1: Add the default (empty) allowlist**

In `config/config.exs`, directly below the adapter config lines (the block with `:billing_provider`, `:llm_provider`, `:storage_provider`), add:

```elixir
# Operator allowlist for the /admin surface. Overridden per-environment;
# populated from ADMIN_EMAILS in production (see config/runtime.exs).
config :perfect_paper, :admin_emails, []
```

- [ ] **Step 2: Add a known admin email for tests**

In `config/test.exs`, add (anywhere in the file, e.g. near the top after the first `config` call):

```elixir
# A fixed admin email the LiveView tests log in as.
config :perfect_paper, :admin_emails, ["admin@perfectpaper.test"]
```

- [ ] **Step 3: Read the allowlist from the environment in prod**

In `config/runtime.exs`, inside the existing `if config_env() == :prod do` block, add:

```elixir
  config :perfect_paper, :admin_emails,
    System.get_env("ADMIN_EMAILS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
```

- [ ] **Step 4: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings.

- [ ] **Step 5: Commit**

```bash
git add config/config.exs config/test.exs config/runtime.exs
git commit -m "feat(admin): add admin_emails allowlist config"
```

---

## Task 3: `require_admin` on_mount hook + admin route

**Files:**
- Modify: `lib/perfect_paper_web/user_auth.ex`
- Modify: `lib/perfect_paper_web/router.ex`

This wiring is verified end-to-end by Task 4's LiveView tests (access control). Build it before the LiveView so the route exists.

- [ ] **Step 1: Add the `admin_emails/0` helper and the on_mount clause**

In `lib/perfect_paper_web/user_auth.ex`, add a new `on_mount` clause directly after the `on_mount(:require_sudo_mode, ...)` clause (around line 246):

```elixir
  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    if user && String.downcase(user.email) in admin_emails() do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You do not have access to that page.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end
```

Then add the public helper. Put it just below the `signed_in_path/1` clauses (after the `signed_in_path(_), do: ~p"/"` line, around line 265):

```elixir
  @doc "Returns the configured admin email allowlist, downcased."
  @spec admin_emails() :: [String.t()]
  def admin_emails do
    :perfect_paper
    |> Application.get_env(:admin_emails, [])
    |> Enum.map(&String.downcase/1)
  end
```

- [ ] **Step 2: Add the admin route**

In `lib/perfect_paper_web/router.ex`, add this scope after the `:require_authenticated_user` scope block (after the block ending at line 82, before the `scope "/"` with `:current_user`):

```elixir
  scope "/admin", PerfectPaperWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_admin,
      on_mount: [
        {PerfectPaperWeb.UserAuth, :require_authenticated},
        {PerfectPaperWeb.UserAuth, :require_admin}
      ] do
      live "/credits", AdminLive.Credits, :index
    end
  end
```

- [ ] **Step 3: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: compiles. (The route references `AdminLive.Credits`, created in Task 4. At this step Phoenix compiles route refs lazily, but if you get an "undefined module" warning, proceed to Task 4 and run compile again there — do NOT add a stub.)

> If Step 3 fails to compile because the module does not yet exist, that is expected; commit Task 3 together with Task 4 instead of separately. Otherwise commit now.

- [ ] **Step 4: Commit**

```bash
git add lib/perfect_paper_web/user_auth.ex lib/perfect_paper_web/router.ex
git commit -m "feat(admin): gate /admin/credits behind require_admin on_mount"
```

---

## Task 4: `AdminLive.Credits` LiveView + template

**Files:**
- Create: `lib/perfect_paper_web/live/admin_live/credits.ex`
- Create: `lib/perfect_paper_web/live/admin_live/credits.html.heex`
- Test: `test/perfect_paper_web/live/admin_live/credits_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/perfect_paper_web/live/admin_live/credits_test.exs`:

```elixir
defmodule PerfectPaperWeb.AdminLive.CreditsTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Credits
  alias PerfectPaper.Credits.CreditEvent
  alias PerfectPaper.Repo

  defp log_in_admin(conn) do
    admin = user_fixture(%{email: "admin@perfectpaper.test"})
    {log_in_user(conn, admin), admin}
  end

  describe "access control" do
    test "redirects a non-admin authenticated user", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/credits")
    end

    test "allows an admin user", %{conn: conn} do
      {conn, _admin} = log_in_admin(conn)
      assert {:ok, _lv, html} = live(conn, ~p"/admin/credits")
      assert html =~ "Comp credits"
    end
  end

  describe "lookup and granting" do
    test "looks up a user and shows their balance", %{conn: conn} do
      {conn, _admin} = log_in_admin(conn)
      target = user_fixture()
      Credits.grant(target.id, 40, "seed")

      {:ok, lv, _html} = live(conn, ~p"/admin/credits")

      html =
        lv
        |> form("#lookup-form", %{email: target.email})
        |> render_submit()

      assert html =~ target.email
      assert html =~ "40"
    end

    test "shows an error for an unknown email", %{conn: conn} do
      {conn, _admin} = log_in_admin(conn)
      {:ok, lv, _html} = live(conn, ~p"/admin/credits")

      html =
        lv
        |> form("#lookup-form", %{email: "nobody@example.com"})
        |> render_submit()

      assert html =~ "No account found"
    end

    test "grants comp credits, updates the balance, and records attribution",
         %{conn: conn} do
      {conn, admin} = log_in_admin(conn)
      target = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin/credits")
      lv |> form("#lookup-form", %{email: target.email}) |> render_submit()

      html =
        lv
        |> form("#grant-form", %{grant: %{amount: "25", reason: "sorry for the outage"}})
        |> render_submit()

      assert html =~ "25"
      assert Credits.balance(target.id) == 25

      [event] = Repo.all(CreditEvent)
      assert event.metadata["kind"] == "comp"
      assert event.metadata["granted_by"] == admin.id
    end

    test "rejects a non-positive amount without writing", %{conn: conn} do
      {conn, _admin} = log_in_admin(conn)
      target = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin/credits")
      lv |> form("#lookup-form", %{email: target.email}) |> render_submit()

      lv
      |> form("#grant-form", %{grant: %{amount: "0", reason: "nope"}})
      |> render_submit()

      assert Credits.balance(target.id) == 0
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/perfect_paper_web/live/admin_live/credits_test.exs`
Expected: FAIL — the route/module does not exist yet (`UndefinedFunctionError` / no route).

- [ ] **Step 3: Create the LiveView module**

Create `lib/perfect_paper_web/live/admin_live/credits.ex`:

```elixir
defmodule PerfectPaperWeb.AdminLive.Credits do
  @moduledoc """
  Operator-only page to grant goodwill ("comp") credits to an account.

  Look up an account by email, see its current balance, and issue a credit grant
  with a free-form reason. Access is gated to the configured admin allowlist via
  the `:require_admin` on_mount hook. All writes route through the
  `PerfectPaper.Credits` context.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Accounts, Credits}

  @grant_types %{amount: :integer, reason: :string}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Comp credits",
       target_user: nil,
       balance: nil,
       lookup_error: nil
     )
     |> assign(:lookup_form, to_form(%{"email" => ""}, as: :lookup))
     |> assign(:grant_form, to_form(grant_changeset(%{}), as: :grant))}
  end

  @impl true
  def handle_event("lookup", %{"email" => email}, socket) do
    case Accounts.get_user_by_email(String.trim(email)) do
      nil ->
        {:noreply,
         assign(socket,
           target_user: nil,
           balance: nil,
           lookup_error: "No account found for that email."
         )}

      user ->
        {:noreply,
         socket
         |> assign(target_user: user, balance: Credits.balance(user.id), lookup_error: nil)
         |> assign(:grant_form, to_form(grant_changeset(%{}), as: :grant))}
    end
  end

  def handle_event("grant", %{"grant" => params}, %{assigns: %{target_user: user}} = socket)
      when not is_nil(user) do
    case Ecto.Changeset.apply_action(grant_changeset(params), :insert) do
      {:ok, %{amount: amount, reason: reason}} ->
        admin_id = socket.assigns.current_scope.user.id

        case Credits.comp_account(user.id, amount, reason, admin_id) do
          {:ok, _event} ->
            {:noreply,
             socket
             |> assign(balance: Credits.balance(user.id))
             |> assign(:grant_form, to_form(grant_changeset(%{}), as: :grant))
             |> put_flash(:info, "Granted #{amount} credits to #{user.email}.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not record the grant.")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :grant_form, to_form(changeset, as: :grant))}
    end
  end

  defp grant_changeset(attrs) do
    {%{}, @grant_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@grant_types))
    |> Ecto.Changeset.update_change(:reason, &String.trim/1)
    |> Ecto.Changeset.validate_required([:amount, :reason])
    |> Ecto.Changeset.validate_number(:amount, greater_than: 0)
  end
end
```

- [ ] **Step 4: Create the collocated template**

Create `lib/perfect_paper_web/live/admin_live/credits.html.heex`:

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <div class="mx-auto max-w-2xl px-4 py-8 space-y-8">
    <header class="space-y-1">
      <h1 class="ds-h2">Comp credits</h1>
      <p class="ds-p text-base-content/70">
        Grant goodwill credits to an account when something breaks or a customer
        is unhappy with results.
      </p>
    </header>

    <.form for={@lookup_form} id="lookup-form" phx-submit="lookup" class="flex items-end gap-2">
      <div class="flex-1">
        <.input field={@lookup_form[:email]} type="email" label="Account email" />
      </div>
      <.button type="submit" class="btn-primary">Look up</.button>
    </.form>

    <p :if={@lookup_error} class="text-sm text-error">{@lookup_error}</p>

    <section
      :if={@target_user}
      class="space-y-6 rounded-box border border-base-300 p-6"
    >
      <div class="flex items-baseline justify-between">
        <div>
          <p class="ds-eyebrow">Account</p>
          <p class="font-medium">{@target_user.email}</p>
        </div>
        <div class="text-right">
          <p class="ds-eyebrow">Current balance</p>
          <p class="font-display text-2xl">{@balance}</p>
        </div>
      </div>

      <.form for={@grant_form} id="grant-form" phx-submit="grant" class="space-y-4">
        <.input field={@grant_form[:amount]} type="number" label="Credits to grant" min="1" />
        <.input
          field={@grant_form[:reason]}
          type="text"
          label="Reason"
          placeholder="sorry for the outage"
        />
        <.button type="submit" class="btn-primary">Grant credits</.button>
      </.form>
    </section>
  </div>
</Layouts.app>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/perfect_paper_web/live/admin_live/credits_test.exs`
Expected: PASS (all five tests).

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/live/admin_live/ test/perfect_paper_web/live/admin_live/
git commit -m "feat(admin): add comp-credits LiveView page"
```

If Task 3's route commit was deferred (its Step 3 note), include `lib/perfect_paper_web/router.ex` and `lib/perfect_paper_web/user_auth.ex` in this commit as well.

---

## Task 5: Pre-merge verification and merge

**Files:** none (verification + git only)

- [ ] **Step 1: Run the full relevant suite**

Run: `mix test test/perfect_paper/credits_test.exs test/perfect_paper_web/live/admin_live/credits_test.exs`
Expected: PASS, no failures.

- [ ] **Step 2: Run precommit**

Run: `mix precommit`
Expected: compiles with `--warnings-as-errors`, formatted, full suite green. Fix anything red before merging — broken tests are in scope.

- [ ] **Step 3: Merge back to main**

```bash
git checkout main
git merge --no-ff feat/admin-comp-credits -m "Merge: admin comp-credits page"
```

Report: "committed and merged back to main with no issues."

---

## Self-Review Notes

- **Spec coverage:** comp grant (Task 1) · config allowlist (Task 2) · require_admin gate + route (Task 3) · lookup/balance/grant LiveView with error handling (Task 4) · tests for context + all four page behaviors + non-positive rejection · merge (Task 5). All spec sections covered.
- **Out-of-scope items** (recent-grants log, role column, REST endpoint, revoke) are intentionally absent.
- **Type consistency:** `comp_account/4` signature identical in spec, Task 1 impl, and LiveView call site. Form names (`lookup`/`grant`, fields `email`/`amount`/`reason`) match between template, LiveView events, and tests. `admin_emails/0` defined in Task 3 and consumed by the `:require_admin` clause in the same file.
