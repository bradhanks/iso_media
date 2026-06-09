defmodule PerfectPaper.Billing.ContractContextTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Billing
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    owner = user_fixture()
    org = organization_fixture(owner)
    %{org: org, owner: owner}
  end

  defp draft(org, owner, attrs \\ %{}) do
    base = %{
      organization_id: org.id,
      seats: 10,
      price_per_seat_cents: 5000,
      per_seat_credits: 100,
      term_start: Date.utc_today(),
      term_end: Date.add(Date.utc_today(), 365),
      created_by: owner.id
    }

    {:ok, c} = Billing.create_contract(org, Map.merge(base, attrs))
    c
  end

  test "create_contract inserts a draft", %{org: org, owner: owner} do
    c = draft(org, owner)
    assert c.status == :draft
  end

  test "activate_contract sets active; a second active is refused", %{org: org, owner: owner} do
    c1 = draft(org, owner)
    {:ok, _} = Billing.activate_contract(c1)
    c2 = draft(org, owner)
    assert {:error, :active_contract_exists} = Billing.activate_contract(c2)
  end

  test "has_active_contract? is date-aware", %{org: org, owner: owner} do
    c = draft(org, owner)
    {:ok, _} = Billing.activate_contract(c)
    assert Billing.has_active_contract?(org.id)

    expired = draft(org, owner, %{term_start: ~D[2020-01-01], term_end: ~D[2020-12-31]})
    {:ok, _} = Billing.cancel_contract(Repo.get!(PerfectPaper.Billing.Contract, c.id))
    {:ok, _} = Billing.activate_contract(expired)
    refute Billing.has_active_contract?(org.id)
  end

  test "swap_active_contract has no zero-active window", %{org: org, owner: owner} do
    a = draft(org, owner)
    {:ok, a} = Billing.activate_contract(a)
    b = draft(org, owner)
    assert {:ok, _} = Billing.swap_active_contract(org.id, a.id, b.id)
    assert Billing.has_active_contract?(org.id)
  end
end
