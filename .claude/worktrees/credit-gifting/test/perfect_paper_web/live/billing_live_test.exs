defmodule PerfectPaperWeb.BillingLiveTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Billing

  describe "Index" do
    test "billing page shows banded subscription prices for a Band C user", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> put_req_header("cf-ipcountry", "IN")
      {:ok, _lv, html} = live(conn, ~p"/billing")
      # starter monthly Band C
      assert html =~ "$20"
      assert html =~ ~s(phx-value-cadence="annual")
    end

    test "renders the plans and a free-previews summary for a new user", %{conn: conn} do
      user = user_fixture()
      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/billing")

      assert html =~ "Choose your plan"
      # No free plan — a new user is on free previews.
      assert html =~ "free previews"
      assert html =~ "Starter"
      assert html =~ "Professional"
      assert html =~ "$40"
      assert html =~ "$300"
    end

    test "upgrading moves the user onto the chosen plan", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      lv
      |> element("button[phx-click='upgrade'][phx-value-plan='professional']")
      |> render_click()

      sub = Billing.get_subscription_for_user(user.id)
      assert sub.plan == :professional
      assert sub.billing_period == :monthly
      assert render(lv) =~ "Active"
    end

    test "switching to annual cadence grants the 12-month lump", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      # Toggle to annual, then subscribe to Starter.
      lv |> element("button[phx-value-cadence='annual']") |> render_click()

      lv
      |> element("button[phx-click='upgrade'][phx-value-plan='starter']")
      |> render_click()

      sub = Billing.get_subscription_for_user(user.id)
      assert sub.billing_period == :annual
      assert sub.applied_cents == 40_000
      # Annual lump granted up front: 1 review/mo × 12.
      assert PerfectPaper.Credits.balance(user.id) == 12
    end

    test "redirects when not logged in", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/billing")
      assert path =~ "/users/log-in"
    end

    test "buying a pack grants credits via resolve_charge (stub)", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> put_req_header("cf-ipcountry", "US")
      {:ok, lv, _} = live(conn, ~p"/billing")
      lv |> element(~s(button[phx-click="select_tab"][phx-value-tab="credits"])) |> render_click()
      lv |> element(~s([phx-click="buy_pack"][phx-value-pack="pack_3"])) |> render_click()
      assert PerfectPaper.Credits.balance(user.id) == 3
    end
  end

  describe "billing portal" do
    test "no 'Manage billing' button under the stub provider, even with a subscription",
         %{conn: conn} do
      user = user_fixture()
      {:ok, _} = Billing.subscribe(user, :professional, :monthly, "US", "US", [])

      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/billing")

      assert html =~ "Active"
      # The stub has no self-service portal, so the affordance must not appear.
      refute html =~ "Manage billing"
    end
  end

  describe "regional pricing" do
    test "shows banded, struck prices for a discounted region", %{conn: conn} do
      user = user_fixture()

      {:ok, _lv, html} =
        conn
        |> log_in_user(user)
        |> Plug.Conn.put_req_header("cf-ipcountry", "IN")
        |> live(~p"/billing")

      # Band C = 50%: Starter $40 → $20, struck list shown.
      assert html =~ "$20"
      assert html =~ "Regional pricing for your country"
    end

    test "defaults to full price (Band A) with no session band", %{conn: conn} do
      user = user_fixture()
      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/billing")

      assert html =~ "$40"
      refute html =~ "Regional pricing for your country"
    end
  end

  describe "credit packs" do
    test "buying a pack grants the bundle's review credits + records an audit", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      lv |> element("button[phx-value-tab='credits']") |> render_click()

      html =
        lv
        |> element("button[phx-click='buy_pack'][phx-value-pack='pack_3']")
        |> render_click()

      assert html =~ "Added 3 review credits"
      assert PerfectPaper.Credits.balance(user.id) == 3
      assert [_audit] = Billing.list_pricing_decisions(user_id: user.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Allowlist guard: String.to_existing_atom must never be called on unvalidated
  # user-supplied phx-value params. Each handler has a `when param in @valid_*`
  # guard and a catch-all `{:noreply, socket}` for unknown values.
  # ---------------------------------------------------------------------------

  describe "allowlist guards on phx-value params" do
    test "select_tab with a valid value switches the tab", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      html = lv |> render_hook("select_tab", %{"tab" => "credits"})
      assert html =~ "Your credits"
    end

    test "select_tab with an invalid value does not crash the process", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      html = lv |> render_hook("select_tab", %{"tab" => "__struct__"})
      # The process must still be alive and render the current page.
      assert html =~ "Choose your plan"
    end

    test "set_cadence with a valid value switches the cadence", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      html = lv |> render_hook("set_cadence", %{"cadence" => "annual"})
      assert html =~ "Annual"
    end

    test "set_cadence with an invalid value does not crash the process", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      html = lv |> render_hook("set_cadence", %{"cadence" => "__struct__"})
      assert html =~ "Choose your plan"
    end

    test "upgrade with a valid plan atom string works", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      lv |> render_hook("upgrade", %{"plan" => "starter"})
      assert Billing.get_subscription_for_user(user.id) != nil
    end

    test "upgrade with an invalid plan value does not crash the process", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      html = lv |> render_hook("upgrade", %{"plan" => "__struct__"})
      assert html =~ "Choose your plan"
      assert Billing.get_subscription_for_user(user.id) == nil
    end

    test "buy_pack with a valid pack key works", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      lv |> render_hook("buy_pack", %{"pack" => "pack_3"})
      assert PerfectPaper.Credits.balance(user.id) == 3
    end

    test "buy_pack with an invalid pack value does not crash the process", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing")

      html = lv |> render_hook("buy_pack", %{"pack" => "__struct__"})
      assert html =~ "Choose your plan"
      assert PerfectPaper.Credits.balance(user.id) == 0
    end
  end
end
