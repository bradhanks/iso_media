defmodule PerfectPaper.Authz.DecisionTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Authz.Decision

  test "create_changeset requires action, resource_type, decision" do
    changeset = Decision.create_changeset(%Decision{}, %{})
    refute changeset.valid?
    errors = errors_on(changeset)
    assert Map.has_key?(errors, :action)
    assert Map.has_key?(errors, :resource_type)
    assert Map.has_key?(errors, :decision)
  end

  test "create_changeset accepts a valid decision row" do
    changeset =
      Decision.create_changeset(%Decision{}, %{
        subject_id: Ecto.UUID.generate(),
        action: "edit",
        resource_type: "session",
        resource_id: Ecto.UUID.generate(),
        decision: "ok",
        reason: "owner"
      })

    assert changeset.valid?
  end
end
