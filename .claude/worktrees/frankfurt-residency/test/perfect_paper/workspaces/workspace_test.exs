defmodule PerfectPaper.Workspaces.WorkspaceTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Workspaces.Workspace

  test "create_changeset trims name and requires user_id + name" do
    uid = Ecto.UUID.generate()
    cs = Workspace.create_changeset(%Workspace{}, %{name: "  Thesis  ", user_id: uid})
    assert cs.valid?
    assert Ecto.Changeset.get_change(cs, :name) == "Thesis"

    refute Workspace.create_changeset(%Workspace{}, %{name: "x"}).valid?
    refute Workspace.create_changeset(%Workspace{}, %{user_id: uid, name: "   "}).valid?
  end

  test "personal_changeset marks is_personal and names it Personal" do
    user = %PerfectPaper.Accounts.User{id: Ecto.UUID.generate()}
    cs = Workspace.personal_changeset(user)
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :is_personal) == true
    assert Ecto.Changeset.get_field(cs, :name) == "Personal"
    assert Ecto.Changeset.get_field(cs, :user_id) == user.id
  end

  test "rename_changeset trims and rejects blank" do
    cs = Workspace.rename_changeset(%Workspace{name: "Old"}, %{name: "  New  "})
    assert Ecto.Changeset.get_change(cs, :name) == "New"
    refute Workspace.rename_changeset(%Workspace{name: "Old"}, %{name: "  "}).valid?
  end

  test "name is bounded at 120 chars (create + rename)" do
    uid = Ecto.UUID.generate()
    ok = String.duplicate("a", 120)
    too_long = String.duplicate("a", 121)

    assert Workspace.create_changeset(%Workspace{}, %{name: ok, user_id: uid}).valid?
    refute Workspace.create_changeset(%Workspace{}, %{name: too_long, user_id: uid}).valid?

    assert Workspace.rename_changeset(%Workspace{name: "Old"}, %{name: ok}).valid?
    refute Workspace.rename_changeset(%Workspace{name: "Old"}, %{name: too_long}).valid?
  end

  test "create_changeset ignores is_personal from attrs (no self-promotion)" do
    uid = Ecto.UUID.generate()
    cs = Workspace.create_changeset(%Workspace{}, %{name: "Lab", user_id: uid, is_personal: true})
    assert cs.valid?
    # is_personal was not cast, so it stays at the schema default (false).
    assert Ecto.Changeset.get_field(cs, :is_personal) == false
    refute Map.has_key?(cs.changes, :is_personal)
  end
end
