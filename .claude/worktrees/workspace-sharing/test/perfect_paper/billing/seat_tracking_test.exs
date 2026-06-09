defmodule PerfectPaper.Billing.SeatTrackingTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Billing, Organizations}
  alias PerfectPaper.Billing.Contract
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    owner = user_fixture()
    org = organization_fixture(owner, %{credit_pool: 0})

    {:ok, c} =
      Billing.create_contract(org, %{
        organization_id: org.id,
        seats: 5,
        per_seat_credits: 10,
        price_per_seat_cents: 1000,
        term_start: Date.utc_today(),
        term_end: Date.add(Date.utc_today(), 365)
      })

    {:ok, c} = Billing.activate_contract(c)
    %{org: org, contract: c}
  end

  test "active_member_count counts only :active memberships", %{org: org} do
    {:ok, _} = Organizations.add_member(org, user_fixture(), :member)
    {:ok, m2} = Organizations.add_member(org, user_fixture(), :member)
    assert Organizations.active_member_count(org.id) == 2
    {:ok, _} = Organizations.deactivate_membership(org, m2.user_id)
    assert Organizations.active_member_count(org.id) == 1
  end

  test "fund_pool atomically increments", %{org: org} do
    before = Organizations.credit_pool_status(org.id).pool
    :ok = Organizations.fund_pool(org.id, 250)
    assert Organizations.credit_pool_status(org.id).pool == before + 250
    :ok = Organizations.fund_pool(org.id, 250)
    assert Organizations.credit_pool_status(org.id).pool == before + 500
  end

  test "bump_peak_seats_for_event raises peak to current active count and never lowers it", %{
    org: org,
    contract: c
  } do
    {:ok, _} = Organizations.add_member(org, user_fixture(), :member)
    {:ok, m2} = Organizations.add_member(org, user_fixture(), :member)

    evt = %PerfectPaper.Events.Event{
      type: :"member.provisioned",
      organization_id: org.id,
      data: %{}
    }

    Billing.bump_peak_seats_for_event(evt)
    assert Repo.get!(Contract, c.id).peak_seats_used == 2

    # deactivate one then bump again — the high-water mark stays at 2
    {:ok, _} = Organizations.deactivate_membership(org, m2.user_id)
    Billing.bump_peak_seats_for_event(evt)
    assert Repo.get!(Contract, c.id).peak_seats_used == 2
  end

  test "bump is a no-op for an org with no active contract" do
    org2 = organization_fixture(user_fixture())

    evt = %PerfectPaper.Events.Event{
      type: :"member.provisioned",
      organization_id: org2.id,
      data: %{}
    }

    assert :ok = Billing.bump_peak_seats_for_event(evt)
  end
end
