defmodule PerfectPaper.Billing.InvoicingTest do
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
        seats: 10,
        price_per_seat_cents: 5000,
        per_seat_credits: 100,
        term_start: Date.utc_today(),
        term_end: Date.add(Date.utc_today(), 365)
      })

    # activate issues the first invoice (funds 10*100 = 1000, peak reset to 0)
    {:ok, c} = Billing.activate_contract(c)
    # simulate a high-water peak of 12 (2 over the 10 seats) for the next invoice
    Repo.update_all(from(x in Contract, where: x.id == ^c.id), set: [peak_seats_used: 12])
    %{org: org, contract: Repo.get!(Contract, c.id)}
  end

  test "activate issued a first invoice and funded the pool", %{org: org} do
    assert [_first] = Billing.list_invoices(org.id)
    assert Organizations.credit_pool_status(org.id).pool == 10 * 100
  end

  test "issue_invoice bills seats+overage, funds the pool by funded_credits, resets peak, non-enumerable number",
       %{org: org, contract: c} do
    before = Organizations.credit_pool_status(org.id).pool
    {:ok, inv} = Billing.issue_invoice(c, Date.add(Date.utc_today(), 31))
    assert inv.seats_billed == 10 and inv.seat_overage == 2
    assert inv.amount_cents == 12 * 5000
    assert inv.funded_credits == 12 * 100
    assert Organizations.credit_pool_status(org.id).pool == before + 12 * 100
    assert Repo.get!(Contract, c.id).peak_seats_used == Organizations.active_member_count(org.id)
    assert inv.number =~ ~r/^INV-\d{6}-[A-Z2-7]{8}$/
  end

  test "mark_invoice_paid sets :paid + paid_at", %{contract: c} do
    {:ok, inv} = Billing.issue_invoice(c, Date.add(Date.utc_today(), 31))
    {:ok, paid} = Billing.mark_invoice_paid(inv)
    assert paid.status == :paid and paid.paid_at
  end

  test "void_invoice claws back exactly funded_credits", %{org: org, contract: c} do
    {:ok, inv} = Billing.issue_invoice(c, Date.add(Date.utc_today(), 31))
    after_issue = Organizations.credit_pool_status(org.id).pool
    {:ok, voided} = Billing.void_invoice(inv)
    assert voided.status == :void
    assert Organizations.credit_pool_status(org.id).pool == after_issue - inv.funded_credits
  end

  test "voiding an already-void invoice is rejected and does NOT claw back twice", %{
    org: org,
    contract: c
  } do
    {:ok, inv} = Billing.issue_invoice(c, Date.add(Date.utc_today(), 31))
    {:ok, voided} = Billing.void_invoice(inv)
    after_first_void = Organizations.credit_pool_status(org.id).pool

    assert {:error, :already_void} = Billing.void_invoice(voided)
    assert Organizations.credit_pool_status(org.id).pool == after_first_void
  end

  test "voiding the SAME stale :issued struct twice claws back only once (concurrent-safe)", %{
    org: org,
    contract: c
  } do
    {:ok, inv} = Billing.issue_invoice(c, Date.add(Date.utc_today(), 31))
    after_issue = Organizations.credit_pool_status(org.id).pool

    # Both calls receive the same :issued struct — as two concurrent requests
    # would, each having loaded the invoice before either committed. The status
    # transition must be atomic so only one claws back the pool.
    assert {:ok, _} = Billing.void_invoice(inv)
    assert {:error, :already_void} = Billing.void_invoice(inv)

    assert Organizations.credit_pool_status(org.id).pool == after_issue - inv.funded_credits
  end

  test "re-issuing the same period is rejected and does NOT double-fund the pool", %{
    org: org,
    contract: c
  } do
    period = Date.add(Date.utc_today(), 31)
    {:ok, _inv} = Billing.issue_invoice(c, period)
    after_first = Organizations.credit_pool_status(org.id).pool

    assert {:error, %Ecto.Changeset{}} = Billing.issue_invoice(c, period)
    assert Organizations.credit_pool_status(org.id).pool == after_first
  end
end
