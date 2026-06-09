defmodule PerfectPaper.Organizations.GroupMembershipTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Organizations.GroupMembership

  test "create_changeset requires group_id and user_id" do
    changeset = GroupMembership.create_changeset(%GroupMembership{}, %{})
    refute changeset.valid?
    assert %{group_id: _, user_id: _} = errors_on(changeset)
  end

  test "create_changeset accepts a valid membership with a role" do
    changeset =
      GroupMembership.create_changeset(%GroupMembership{}, %{
        group_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        role: :editor
      })

    assert changeset.valid?
    assert get_change(changeset, :role) == :editor
  end
end
