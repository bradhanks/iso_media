defmodule PerfectPaper.Billing.EventsTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Billing, Events}
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  test "contract create/activate + invoice issue/paid emit domain events" do
    owner = user_fixture()
    org = organization_fixture(owner, %{credit_pool: 0})

    Events.subscribe(:"contract.created")
    Events.subscribe(:"contract.activated")
    Events.subscribe(:"invoice.issued")
    Events.subscribe(:"invoice.paid")

    {:ok, c} =
      Billing.create_contract(org, %{
        organization_id: org.id,
        seats: 2,
        per_seat_credits: 1,
        price_per_seat_cents: 100,
        term_start: Date.utc_today(),
        term_end: Date.add(Date.utc_today(), 365)
      })

    assert_receive {:event, %Events.Event{type: :"contract.created"}}

    {:ok, _} = Billing.activate_contract(c)
    assert_receive {:event, %Events.Event{type: :"contract.activated"}}
    # activation issues the first invoice
    assert_receive {:event, %Events.Event{type: :"invoice.issued"}}

    [inv] = Billing.list_invoices(org.id)
    {:ok, _} = Billing.mark_invoice_paid(inv)
    assert_receive {:event, %Events.Event{type: :"invoice.paid"}}
  end
end
