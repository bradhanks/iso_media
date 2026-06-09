defmodule PerfectPaperWeb.AdminLive.Billing do
  @moduledoc """
  Operator-only billing admin: look up an org, create/activate its enterprise
  contract, and mark invoices paid. Access is gated to the admin allowlist via
  the `:require_admin` on_mount hook on its `live_session`.
  """
  use PerfectPaperWeb, :live_view
  alias PerfectPaper.{Billing, Organizations}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Billing admin"),
       org: nil,
       contract: nil,
       invoices: [],
       lookup_error: nil
     )}
  end

  @impl true
  def handle_event("lookup", %{"org_id" => org_id}, socket) do
    case Organizations.get_organization(org_id) do
      {:ok, org} ->
        {:noreply, load(socket, org)}

      {:error, :not_found} ->
        {:noreply, assign(socket, org: nil, lookup_error: gettext("Organization not found"))}
    end
  end

  def handle_event("create", params, socket) do
    org = socket.assigns.org

    attrs = %{
      seats: to_int(params["seats"]),
      price_per_seat_cents: to_int(params["price_per_seat_cents"]),
      per_seat_credits: to_int(params["per_seat_credits"]),
      interval: params["interval"] || "monthly",
      term_start: params["term_start"],
      term_end: params["term_end"],
      po_number: params["po_number"]
    }

    case Billing.create_contract(org, attrs) do
      {:ok, _} -> {:noreply, load(socket, org)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Invalid contract terms"))}
    end
  end

  def handle_event("activate", _params, socket) do
    org = socket.assigns.org

    case Billing.activate_latest_draft(org.id) do
      {:ok, _} ->
        {:noreply, load(socket, org)}

      {:error, :active_contract_exists} ->
        {:noreply, put_flash(socket, :error, gettext("An active contract already exists"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("No draft contract to activate"))}
    end
  end

  def handle_event("mark-paid", %{"id" => id}, socket) do
    org = socket.assigns.org

    case Billing.get_invoice(org.id, id) do
      nil ->
        {:noreply, socket}

      inv ->
        {:ok, _} = Billing.mark_invoice_paid(inv)
        {:noreply, load(socket, org)}
    end
  end

  defp load(socket, org) do
    assign(socket,
      org: org,
      lookup_error: nil,
      contract: Billing.get_contract(org.id),
      invoices: Billing.list_invoices(org.id)
    )
  end

  defp to_int(nil), do: 0
  defp to_int(""), do: 0
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
end
