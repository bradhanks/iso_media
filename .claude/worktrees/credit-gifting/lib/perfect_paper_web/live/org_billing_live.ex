defmodule PerfectPaperWeb.OrgBillingLive do
  @moduledoc """
  Read-only org-admin billing dashboard: contract terms, seats used vs
  contracted (+ overage), credit-pool balance (incl. negative overage), and the
  invoice list. Management lives in the internal `/admin/billing` surface.
  """
  use PerfectPaperWeb, :live_view
  alias PerfectPaper.{Billing, Organizations}

  @impl true
  def mount(%{"org_id" => org_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, org} <- Organizations.get_organization(org_id),
         true <- Organizations.admin?(org, user.id) do
      {:ok, assign_billing(socket, org)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You must be an organization admin to view billing."))
         |> push_navigate(to: ~p"/new")}
    end
  end

  defp assign_billing(socket, org) do
    contract = Billing.get_contract(org.id)
    used = Organizations.active_member_count(org.id)

    assign(socket,
      org: org,
      contract: contract,
      seats_used: used,
      seat_overage: if(contract, do: max(0, used - contract.seats), else: 0),
      pool: Organizations.credit_pool_status(org.id).pool,
      invoices: Billing.list_invoices(org.id)
    )
  end

  @doc "Formats integer cents as a dollar string."
  def dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  def dollars(_), do: "—"
end
