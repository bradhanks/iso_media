defmodule PerfectPaper.Billing.ContractTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Billing.Contract

  test "create_changeset requires org, seats, term dates and positive seats" do
    cs =
      Contract.create_changeset(%Contract{}, %{
        organization_id: Ecto.UUID.generate(),
        seats: 0,
        term_start: ~D[2026-01-01],
        term_end: ~D[2026-12-31]
      })

    refute cs.valid?
    assert %{seats: _} = errors_on(cs)
  end

  test "create_changeset accepts a valid draft" do
    cs =
      Contract.create_changeset(%Contract{}, %{
        organization_id: Ecto.UUID.generate(),
        seats: 10,
        price_per_seat_cents: 5000,
        per_seat_credits: 100,
        term_start: ~D[2026-01-01],
        term_end: ~D[2026-12-31]
      })

    assert cs.valid?
  end
end
