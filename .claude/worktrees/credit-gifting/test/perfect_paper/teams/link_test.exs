defmodule PerfectPaper.Teams.LinkTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Teams.Link

  test "changeset requires user_id, aad_object_id, tenant_id" do
    refute Link.changeset(%Link{}, %{}).valid?
  end

  test "changeset accepts a valid link" do
    cs =
      Link.changeset(%Link{}, %{
        user_id: Ecto.UUID.generate(),
        aad_object_id: "oid-1",
        tenant_id: "tenant-1",
        conversation_reference: %{"a" => 1}
      })

    assert cs.valid?
  end
end
