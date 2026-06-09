defmodule PerfectPaperWeb.HistoryLiveTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  alias PerfectPaper.{Authz, Repo, Workspaces}

  describe "Index" do
    test "lists the active workspace's sessions", %{conn: conn} do
      user = user_fixture()
      ws = Workspaces.personal_workspace(user)
      session = session_fixture(user: user, title: "My Paper", workspace_id: ws.id)
      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/w/#{ws.id}/reviews")
      assert html =~ "Proofreading history"
      assert html =~ session.title
    end

    test "redirects when not logged in", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/w/#{Ecto.UUID.generate()}/reviews")

      assert path =~ "/users/log-in"
    end

    test "excludes reviews that live in a different workspace", %{conn: conn} do
      user = user_fixture()
      a = Workspaces.personal_workspace(user)
      {:ok, b} = Workspaces.create_workspace(user, %{name: "B"})
      session_fixture(user: user, title: "In A", workspace_id: a.id)
      session_fixture(user: user, title: "In B", workspace_id: b.id)

      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/w/#{a.id}/reviews")
      assert html =~ "In A"
      refute html =~ "In B"
    end

    test "shows a comment count without an N+1 preload", %{conn: conn} do
      user = user_fixture()
      ws = Workspaces.personal_workspace(user)
      session = session_fixture(user: user, title: "Counted", workspace_id: ws.id)
      comment_fixture(session)
      comment_fixture(session)

      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/w/#{ws.id}/reviews")
      assert html =~ "2 comments"
    end

    test "deletes a session and removes it from the list", %{conn: conn} do
      user = user_fixture()
      ws = Workspaces.personal_workspace(user)
      session = session_fixture(user: user, title: "Doomed", workspace_id: ws.id)
      {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/w/#{ws.id}/reviews")
      assert html =~ "Doomed"

      html =
        lv
        |> element("#session-#{session.id}-delete")
        |> render_click()

      refute html =~ "Doomed"
      assert PerfectPaper.History.get_session(session.id, Authz.load_subject(user)) == nil
    end
  end

  describe "Show" do
    test "renders feedback and dismisses a comment", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session, suggestion: "the", original_text: "teh")

      {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/history/#{session.id}")
      assert html =~ "the"

      html =
        lv
        |> element("button[phx-click='dismiss'][phx-value-id='#{comment.id}']")
        |> render_click()

      assert html =~ "Undo"
    end

    test "marks the session viewed when the owner opens it", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)
      refute Repo.reload!(session).viewed

      {:ok, _lv, _html} = conn |> log_in_user(user) |> live(~p"/history/#{session.id}")

      assert Repo.reload!(session).viewed
    end
  end
end
