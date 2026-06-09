defmodule PerfectPaperWeb.PagesSmokeTest do
  @moduledoc """
  Smoke coverage that every wired page mounts and renders for the right audience.
  Verifies the screenshot→LiveView pass boots end to end under auth.
  """
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  describe "public marketing pages" do
    test "GET /examples renders", %{conn: conn} do
      assert conn |> get(~p"/examples") |> html_response(200) =~ "PerfectPaper"
    end

    test "GET /contact renders", %{conn: conn} do
      assert conn |> get(~p"/contact") |> html_response(200) =~ "PerfectPaper"
    end
  end

  describe "authenticated app pages" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "/account mounts", %{conn: conn} do
      assert {:ok, _lv, html} = live(conn, ~p"/account")
      assert html =~ "Account"
    end

    test "/earn mounts", %{conn: conn} do
      assert {:ok, _lv, _html} = live(conn, ~p"/earn")
    end

    test "/w/:workspace_id/review/:id mounts for an owned session", %{conn: conn, user: user} do
      ws = PerfectPaper.Workspaces.personal_workspace(user)
      session = session_fixture(user: user)
      comment = comment_fixture(session)
      {:ok, _lv, html} = live(conn, ~p"/w/#{ws.id}/review/#{session.id}")
      assert html =~ comment.suggestion
    end
  end

  describe "auth gating" do
    test "/account redirects when logged out", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/account")
    end
  end
end
