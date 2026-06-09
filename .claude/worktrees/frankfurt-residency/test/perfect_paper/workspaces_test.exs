defmodule PerfectPaper.WorkspacesTest do
  use PerfectPaper.DataCase, async: true

  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Workspaces

  test "personal_workspace creates once and is idempotent" do
    user = user_fixture()
    a = Workspaces.personal_workspace(user)
    b = Workspaces.personal_workspace(user)
    assert a.id == b.id
    assert a.is_personal
    assert a.name == "Personal"
  end

  test "a duplicate Personal insert maps to a changeset error, not a raise" do
    # The recovery premise: insert_personal/1 only survives a race because the
    # partial unique index surfaces as {:error, changeset}. Prove that here
    # deterministically (true parallel processes can't share the test sandbox
    # connection, so this asserts the constraint mapping instead).
    user = user_fixture()
    Workspaces.personal_workspace(user)

    assert {:error, changeset} =
             user
             |> PerfectPaper.Workspaces.Workspace.personal_changeset()
             |> PerfectPaper.Repo.insert()

    refute changeset.valid?
    assert "has already been taken" in errors_on(changeset).user_id

    # And personal_workspace still returns the original — never a duplicate.
    assert Workspaces.list_workspaces(user) |> Enum.count(& &1.is_personal) == 1
  end

  test "list_workspaces returns Personal first, then by name" do
    user = user_fixture()
    Workspaces.personal_workspace(user)
    {:ok, _} = Workspaces.create_workspace(user, %{name: "Zeta"})
    {:ok, _} = Workspaces.create_workspace(user, %{name: "Alpha"})
    names = user |> Workspaces.list_workspaces() |> Enum.map(& &1.name)
    assert names == ["Personal", "Alpha", "Zeta"]
  end

  test "create_workspace is owned by the user; get/rename enforce ownership" do
    user = user_fixture()
    other = user_fixture()
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "Lab"})
    assert ws.user_id == user.id

    assert {:ok, ^ws} = Workspaces.get_workspace(ws.id, user)
    assert {:error, :not_found} = Workspaces.get_workspace(ws.id, other)
    assert {:error, :not_found} = Workspaces.get_workspace("not-a-uuid", user)

    assert {:ok, renamed} = Workspaces.rename_workspace(ws, user, "Renamed Lab")
    assert renamed.name == "Renamed Lab"
    assert {:error, :not_found} = Workspaces.rename_workspace(ws, other, "Hijack")
  end

  test "delete_workspace refuses Personal and rejects non-owners" do
    user = user_fixture()
    other = user_fixture()
    personal = Workspaces.personal_workspace(user)
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "Temp"})

    assert {:error, :personal} = Workspaces.delete_workspace(personal, user)
    assert {:error, :not_found} = Workspaces.delete_workspace(ws, other)
    assert {:ok, _} = Workspaces.delete_workspace(ws, user)
    assert {:error, :not_found} = Workspaces.get_workspace(ws.id, user)
  end

  test "delete_workspace reassigns its reviews to Personal" do
    user = user_fixture()
    personal = Workspaces.personal_workspace(user)
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "Temp"})

    {:ok, session} =
      PerfectPaper.History.begin_session(%{
        user_id: user.id,
        title: "moves home",
        workspace_id: ws.id
      })

    assert {:ok, _} = Workspaces.delete_workspace(ws, user)
    assert PerfectPaper.Repo.reload!(session).workspace_id == personal.id
  end

  test "a rejected delete (non-owner) has no side effects" do
    user = user_fixture()
    other = user_fixture()
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "Temp"})

    {:ok, session} =
      PerfectPaper.History.begin_session(%{
        user_id: user.id,
        title: "stays put",
        workspace_id: ws.id
      })

    assert {:error, :not_found} = Workspaces.delete_workspace(ws, other)
    # Workspace still exists and its review was not reassigned.
    assert {:ok, _} = Workspaces.get_workspace(ws.id, user)
    assert PerfectPaper.Repo.reload!(session).workspace_id == ws.id
  end

  test "set_active persists only a workspace the user owns" do
    user = user_fixture()
    {:ok, ws} = Workspaces.create_workspace(user, %{name: "W"})
    assert {:ok, updated} = Workspaces.set_active(user, ws.id)
    assert updated.active_workspace_id == ws.id

    # A workspace the user doesn't own is rejected and leaves the pointer unchanged.
    assert {:error, :not_found} = Workspaces.set_active(updated, Ecto.UUID.generate())
    assert PerfectPaper.Repo.reload!(user).active_workspace_id == ws.id
  end
end
