defmodule PerfectPaperWeb.OrgBillingLiveTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  alias PerfectPaper.Billing

  setup %{conn: conn} do
    owner = user_fixture()
    org = organization_fixture(owner, %{credit_pool: 0})
    %{conn: log_in_user(conn, owner), org: org}
  end

  test "org-admin sees the dashboard (no contract)", %{conn: conn, org: org} do
    {:ok, _lv, html} = live(conn, ~p"/orgs/#{org.id}/billing")
    assert html =~ "No enterprise contract"
  end

  test "shows contract + seats + pool + invoices once active", %{conn: conn, org: org} do
    {:ok, c} =
      Billing.create_contract(org, %{
        organization_id: org.id,
        seats: 4,
        per_seat_credits: 10,
        price_per_seat_cents: 1000,
        term_start: Date.utc_today(),
        term_end: Date.add(Date.utc_today(), 365)
      })

    {:ok, _} = Billing.activate_contract(c)
    {:ok, _lv, html} = live(conn, ~p"/orgs/#{org.id}/billing")
    assert html =~ ~s(id="billing-seats-used")
    assert html =~ ~s(id="billing-pool")
  end

  test "non-admin is redirected", %{conn: conn, org: org} do
    other = user_fixture()

    assert {:error, {:live_redirect, %{to: path}}} =
             conn |> log_in_user(other) |> live(~p"/orgs/#{org.id}/billing")

    refute path =~ "/billing"
  end
end
