defmodule PerfectPaperWeb.Api.BillingJSON do
  @moduledoc "Renders billing contracts + invoices. Money is integer cents."
  alias PerfectPaper.Organizations

  @doc "Renders the org's contract + live seat usage + pool (or `configured: false`)."
  def show(%{org: org, contract: nil}) do
    %{configured: false, credit_pool: Organizations.credit_pool_status(org.id).pool}
  end

  def show(%{org: org, contract: contract}) do
    used = Organizations.active_member_count(org.id)

    Map.merge(contract_fields(contract), %{
      seats_used: used,
      seat_overage: max(0, used - contract.seats),
      credit_pool: Organizations.credit_pool_status(org.id).pool
    })
  end

  @doc "Renders a list of invoices."
  def invoices(%{invoices: invoices}), do: Enum.map(invoices, &invoice_fields/1)

  @doc "Renders a single invoice."
  def invoice(%{invoice: invoice}), do: invoice_fields(invoice)

  defp contract_fields(c) do
    %{
      id: c.id,
      status: c.status,
      seats: c.seats,
      price_per_seat_cents: c.price_per_seat_cents,
      per_seat_credits: c.per_seat_credits,
      interval: c.interval,
      term_start: c.term_start,
      term_end: c.term_end,
      po_number: c.po_number,
      net_terms_days: c.net_terms_days
    }
  end

  defp invoice_fields(i) do
    %{
      id: i.id,
      number: i.number,
      period_start: i.period_start,
      period_end: i.period_end,
      seats_billed: i.seats_billed,
      seat_overage: i.seat_overage,
      amount_cents: i.amount_cents,
      status: i.status,
      issued_at: i.issued_at,
      due_at: i.due_at,
      paid_at: i.paid_at
    }
  end
end
