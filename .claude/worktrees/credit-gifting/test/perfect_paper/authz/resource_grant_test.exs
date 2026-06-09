defmodule PerfectPaper.Authz.ResourceGrantTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Authz.ResourceGrant

  test "create_changeset requires resource, subject, and role" do
    changeset = ResourceGrant.create_changeset(%ResourceGrant{}, %{})
    refute changeset.valid?
    errors = errors_on(changeset)
    assert Map.has_key?(errors, :resource_type)
    assert Map.has_key?(errors, :resource_id)
    assert Map.has_key?(errors, :subject_type)
    assert Map.has_key?(errors, :subject_id)
    assert Map.has_key?(errors, :role)
  end

  test "create_changeset accepts a valid grant" do
    changeset =
      ResourceGrant.create_changeset(%ResourceGrant{}, %{
        resource_type: :session,
        resource_id: Ecto.UUID.generate(),
        subject_type: :user,
        subject_id: Ecto.UUID.generate(),
        role: :commenter,
        granted_by: Ecto.UUID.generate()
      })

    assert changeset.valid?
  end
end
