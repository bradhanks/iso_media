defmodule PerfectPaper.Billing.ConsumptionTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Billing, Organizations}
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    owner = user_fixture()
    org = organization_fixture(owner, %{credit_pool: 0})

    {:ok, c} =
      Billing.create_contract(org, %{
        organization_id: org.id,
        seats: 2,
        per_seat_credits: 1,
        price_per_seat_cents: 1000,
        term_start: Date.utc_today(),
        term_end: Date.add(Date.utc_today(), 365)
      })

    # activate funds the pool with billed_seats(2) * per_seat_credits(1) = 2
    {:ok, _} = Billing.activate_contract(c)
    %{org: org}
  end

  test "charge_pool draws from a positive pool (fast path)", %{org: org} do
    assert Organizations.credit_pool_status(org.id).pool == 2
    assert :ok = Organizations.charge_pool(org.id, 1)
    assert Organizations.credit_pool_status(org.id).pool == 1
  end

  test "under an active contract the pool may go negative down to the soft floor", %{org: org} do
    # floor = -(seats 2 * per_seat_credits 1 * 2) = -4 ; pool starts at 2
    assert :ok = Organizations.charge_pool(org.id, 5)
    assert Organizations.credit_pool_status(org.id).pool == -3
    # -3 - 3 = -6 < -4 → refused
    assert {:error, :insufficient_credits} = Organizations.charge_pool(org.id, 3)
    assert Organizations.credit_pool_status(org.id).pool == -3
  end

  test "a no-contract org refuses to go negative" do
    org2 = organization_fixture(user_fixture(), %{credit_pool: 0})
    :ok = Organizations.fund_pool(org2.id, 1)
    assert {:error, :insufficient_credits} = Organizations.charge_pool(org2.id, 2)
    assert Organizations.credit_pool_status(org2.id).pool == 1
  end
end
