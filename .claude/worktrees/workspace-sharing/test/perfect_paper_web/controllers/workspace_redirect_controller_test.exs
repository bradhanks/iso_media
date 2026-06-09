defmodule PerfectPaperWeb.WorkspaceRedirectControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Workspaces

  test "/reviews redirects to the user's workspace", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    conn = get(log_in_user(conn, user), ~p"/reviews")
    assert redirected_to(conn) == "/w/#{personal.id}/reviews"
  end

  test "/new redirects to the user's workspace", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    conn = get(log_in_user(conn, user), ~p"/new")
    assert redirected_to(conn) == "/w/#{personal.id}/new"
  end

  test "/history redirects to the user's reviews", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    conn = get(log_in_user(conn, user), ~p"/history")
    assert redirected_to(conn) == "/w/#{personal.id}/reviews"
  end

  test "redirects to the last-used workspace when set", %{conn: conn} do
    user = user_fixture()
    {:ok, lab} = Workspaces.create_workspace(user, %{name: "Lab"})
    {:ok, _} = Workspaces.set_active(user, lab.id)

    conn = get(log_in_user(conn, user), ~p"/reviews")
    assert redirected_to(conn) == "/w/#{lab.id}/reviews"
  end
end
