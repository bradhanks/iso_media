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
