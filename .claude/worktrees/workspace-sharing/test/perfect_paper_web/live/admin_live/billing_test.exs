defmodule PerfectPaperWeb.AdminLive.BillingTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup %{conn: conn} do
    # Statically-configured admin email (config/test.exs) — never mutate the
    # global :admin_emails config (it races other async tests like CreditsTest).
    admin = user_fixture(%{email: "admin@perfectpaper.test"})
    org = organization_fixture(user_fixture(), %{credit_pool: 0})
    %{conn: log_in_user(conn, admin), org: org}
  end

  test "platform-admin can look up an org, create + activate a contract", %{conn: conn, org: org} do
    {:ok, lv, _html} = live(conn, ~p"/admin/billing")

    lv |> form("#org-lookup", %{org_id: org.id}) |> render_submit()

    lv
    |> form("#contract-create", %{
      seats: "5",
      price_per_seat_cents: "1000",
      per_seat_credits: "10",
      interval: "monthly",
      term_start: Date.to_iso8601(Date.utc_today()),
      term_end: Date.to_iso8601(Date.add(Date.utc_today(), 365))
    })
    |> render_submit()

    html = lv |> element("#contract-activate") |> render_click()
    assert html =~ "active"
  end

  test "non-platform-admin is redirected", %{conn: conn} do
    other = user_fixture()
    assert {:error, {:redirect, _}} = conn |> log_in_user(other) |> live(~p"/admin/billing")
  end
end
