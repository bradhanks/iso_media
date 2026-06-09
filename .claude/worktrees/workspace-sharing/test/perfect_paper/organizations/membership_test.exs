defmodule PerfectPaper.Organizations.MembershipTest do
  use PerfectPaper.DataCase, async: true
  import Ecto.Changeset
  alias PerfectPaper.Organizations.Membership

  test "status_changeset deactivates with a timestamp" do
    cs = Membership.status_changeset(%Membership{}, :deactivated)
    assert get_change(cs, :status) == :deactivated
    assert get_change(cs, :deactivated_at)
  end

  test "status_changeset activates and clears deactivated_at" do
    cs =
      Membership.status_changeset(
        %Membership{status: :deactivated, deactivated_at: ~U[2026-01-01 00:00:00Z]},
        :active
      )

    assert get_change(cs, :status) == :active
    # deactivated_at is explicitly set to nil
    assert Map.has_key?(cs.changes, :deactivated_at)
    refute get_change(cs, :deactivated_at)
  end
end
