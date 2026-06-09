defmodule PerfectPaperWeb.AppI18nTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, _updated} = PerfectPaper.Accounts.update_user_locale(user, "de")
    # Reload user so the locale field is present
    user = PerfectPaper.Accounts.get_user!(user.id)
    %{conn: log_in_user(conn, user), user: user}
  end

  test "an authenticated page renders German", %{conn: conn, user: user} do
    ws = PerfectPaper.Workspaces.personal_workspace(user)
    {:ok, _lv, html} = live(conn, ~p"/w/#{ws.id}/reviews")
    assert html =~ "Korrekturverlauf"
  end
end
