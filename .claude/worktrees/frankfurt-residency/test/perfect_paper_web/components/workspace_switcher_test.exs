defmodule PerfectPaperWeb.WorkspaceSwitcherTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Workspaces

  test "the switcher lists the user's workspaces and links to switch", %{conn: conn} do
    user = user_fixture()
    Workspaces.personal_workspace(user)
    {:ok, lab} = Workspaces.create_workspace(user, %{name: "Lab"})

    {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/w/#{lab.id}/reviews")
    assert html =~ "workspace-switcher"
    assert html =~ "Personal"
    assert html =~ "Lab"
    assert html =~ "/w/#{lab.id}/reviews"
    assert html =~ "New workspace"
  end

  test "creating a workspace from the switcher navigates into it", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/w/#{personal.id}/reviews")

    lv |> element("#workspace-switcher [data-role=open-create]") |> render_click()

    lv
    |> form("#workspace-switcher form[phx-submit=create_workspace]", %{"name" => "Grant App"})
    |> render_submit()

    created = user |> Workspaces.list_workspaces() |> Enum.find(&(&1.name == "Grant App"))
    assert created
    assert_redirect(lv, "/w/#{created.id}/reviews")
  end

  test "a global page (account) shows the switcher with the active workspace", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)

    {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/account")
    assert html =~ "workspace-switcher"
    assert html =~ personal.name
  end

  test "renaming the active workspace updates it in place (no navigation)", %{conn: conn} do
    user = user_fixture()
    {:ok, lab} = Workspaces.create_workspace(user, %{name: "Lab"})
    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/w/#{lab.id}/reviews")

    lv |> element("#workspace-switcher [data-role=rename-#{lab.id}]") |> render_click()

    # render_submit returns HTML (not a redirect) — proves we stayed on the page.
    html =
      lv
      |> form("#workspace-switcher form[phx-submit=rename]", %{"name" => "Renamed Lab"})
      |> render_submit()

    assert {:ok, %{name: "Renamed Lab"}} = Workspaces.get_workspace(lab.id, user)
    # The new name shows immediately in the dropdown AND the trigger header.
    assert html =~ "Renamed Lab"
    refute html =~ ">Lab<"
    # Still live — no navigation happened.
    assert render(lv) =~ "Renamed Lab"
  end

  test "deleting the ACTIVE workspace reassigns reviews and navigates to Personal",
       %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    {:ok, temp} = Workspaces.create_workspace(user, %{name: "Temp"})

    {:ok, session} =
      PerfectPaper.History.begin_session(%{
        user_id: user.id,
        title: "moves home",
        workspace_id: temp.id
      })

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/w/#{temp.id}/reviews")

    lv |> element("#workspace-switcher [data-role=delete-#{temp.id}]") |> render_click()
    lv |> element("#workspace-switcher [data-role=confirm-delete-#{temp.id}]") |> render_click()

    assert {:error, :not_found} = Workspaces.get_workspace(temp.id, user)
    assert PerfectPaper.Repo.reload!(session).workspace_id == personal.id
    # You can't stay on a deleted workspace's page → land in Personal.
    assert_redirect(lv, "/w/#{personal.id}/reviews")
  end

  test "deleting a NON-active workspace removes it from the list in place (no navigation)",
       %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    {:ok, temp} = Workspaces.create_workspace(user, %{name: "Temp"})

    {:ok, session} =
      PerfectPaper.History.begin_session(%{
        user_id: user.id,
        title: "moves home",
        workspace_id: temp.id
      })

    # We are IN Personal; deleting "Temp" (not the active one) stays put.
    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/w/#{personal.id}/reviews")

    lv |> element("#workspace-switcher [data-role=delete-#{temp.id}]") |> render_click()

    html =
      lv |> element("#workspace-switcher [data-role=confirm-delete-#{temp.id}]") |> render_click()

    assert {:error, :not_found} = Workspaces.get_workspace(temp.id, user)
    assert PerfectPaper.Repo.reload!(session).workspace_id == personal.id
    # Removed from the dropdown in place; no navigation.
    refute html =~ "Temp"
    assert render(lv) =~ "workspace-switcher"
  end

  test "Personal is renamable but not deletable; others are both", %{conn: conn} do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    {:ok, lab} = Workspaces.create_workspace(user, %{name: "Lab"})
    {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/w/#{lab.id}/reviews")

    # Personal: rename only, no delete.
    assert html =~ "data-role=\"rename-#{personal.id}\""
    refute html =~ "data-role=\"delete-#{personal.id}\""
    # Non-personal: both rename and delete.
    assert html =~ "data-role=\"rename-#{lab.id}\""
    assert html =~ "data-role=\"delete-#{lab.id}\""
  end
end
