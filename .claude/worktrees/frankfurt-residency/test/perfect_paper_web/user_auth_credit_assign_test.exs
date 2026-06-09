defmodule PerfectPaperWeb.UserAuthCreditAssignTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Credits

  test "an authed page shows the low-credit banner when balance <= threshold", %{conn: conn} do
    user = user_fixture()
    Credits.grant(user.id, 1, "test", :paid)
    {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/billing")

    assert html =~ ~s(data-testid="low-credit-banner")
    assert html =~ "/billing"
  end

  test "no banner when balance is comfortably above threshold", %{conn: conn} do
    user = user_fixture()
    Credits.grant(user.id, 50, "test", :paid)
    {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/billing")

    refute html =~ ~s(data-testid="low-credit-banner")
  end
end
