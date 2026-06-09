defmodule PerfectPaper.Organizations.GroupTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Organizations.Group

  test "create_changeset requires organization_id, name, path" do
    changeset = Group.create_changeset(%Group{}, %{})
    refute changeset.valid?
    assert %{organization_id: _, name: _, path: _} = errors_on(changeset)
  end

  test "create_changeset accepts a valid group" do
    changeset =
      Group.create_changeset(%Group{}, %{
        organization_id: Ecto.UUID.generate(),
        name: "English Dept",
        kind: :department,
        path: "abc.def"
      })

    assert changeset.valid?
  end
end
