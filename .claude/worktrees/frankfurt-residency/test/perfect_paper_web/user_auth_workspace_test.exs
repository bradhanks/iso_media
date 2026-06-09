defmodule PerfectPaperWeb.UserAuthWorkspaceTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures
  alias PerfectPaperWeb.UserAuth
  alias PerfectPaper.Workspaces

  defp socket(user) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_scope: PerfectPaper.Accounts.Scope.for_user(user)}
    }
  end

  test "global mode (no :workspace_id) assigns Personal as current + the list" do
    user = user_fixture()
    {:cont, socket} = UserAuth.on_mount(:assign_workspace, %{}, %{}, socket(user))
    assert socket.assigns.current_workspace.is_personal
    assert is_list(socket.assigns.workspaces)
  end

  test "global mode resolves the user's active_workspace_id when set" do
    user = user_fixture()
    {:ok, lab} = Workspaces.create_workspace(user, %{name: "Lab"})
    {:ok, user} = Workspaces.set_active(user, lab.id)

    {:cont, socket} = UserAuth.on_mount(:assign_workspace, %{}, %{}, socket(user))
    assert socket.assigns.current_workspace.id == lab.id
  end

  test "global mode falls back to Personal when active_workspace_id is stale" do
    user = user_fixture()
    stale = %{user | active_workspace_id: Ecto.UUID.generate()}

    {:cont, socket} = UserAuth.on_mount(:assign_workspace, %{}, %{}, socket(stale))
    assert socket.assigns.current_workspace.is_personal
  end

  test "scoped mode assigns the URL workspace when owned" do
    user = user_fixture()
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "Lab"})

    {:cont, socket} =
      UserAuth.on_mount(:assign_workspace, %{"workspace_id" => ws.id}, %{}, socket(user))

    assert socket.assigns.current_workspace.id == ws.id
    # Scoped mount persists the last-used default (spec step 3).
    assert PerfectPaper.Repo.reload!(user).active_workspace_id == ws.id
  end

  test "scoped mode redirects when the workspace isn't the user's" do
    user = user_fixture()
    other = user_fixture()
    {:ok, ws} = Workspaces.create_workspace(other, %{name: "NotYours"})

    assert {:halt, _socket} =
             UserAuth.on_mount(:assign_workspace, %{"workspace_id" => ws.id}, %{}, socket(user))
  end
end
