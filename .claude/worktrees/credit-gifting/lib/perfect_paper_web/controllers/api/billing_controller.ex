defmodule PerfectPaperWeb.Api.BillingController do
  @moduledoc """
  Enterprise billing REST. Two gates: org-admins **view** their contract +
  invoices (`Organizations.admin?`); platform-admins **manage** them (the
  `RequirePlatformAdmin` plug on the management routes) — create/edit a draft,
  activate, mark an invoice paid, void. Amounts are server-computed.
  """
  use PerfectPaperWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PerfectPaper.{Billing, Organizations}
  alias PerfectPaperWeb.Api.Schemas

  action_fallback PerfectPaperWeb.Api.FallbackController

  @manage_keys ~w(seats price_per_seat_cents per_seat_credits interval term_start term_end po_number)

  # ── Org-admin: view ──────────────────────────────────────────────────────────

  operation(:show,
    summary: "Fetch the org's billing contract + live seat usage",
    tags: ["Billing"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [org_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Contract", "application/json", Schemas.BillingContract},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Organization not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"org_id" => org_id}) do
    with {:ok, org} <- admin_org(conn, org_id) do
      render(conn, :show, org: org, contract: Billing.get_contract(org.id))
    end
  end

  operation(:invoices,
    summary: "List the org's invoices",
    tags: ["Billing"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [org_id: [in: :path, type: :string, required: true]],
    responses: [
      ok:
        {"Invoices", "application/json",
         %OpenApiSpex.Schema{type: :array, items: Schemas.BillingInvoice}},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Organization not found", "application/json", Schemas.Error}
    ]
  )

  def invoices(conn, %{"org_id" => org_id}) do
    with {:ok, org} <- admin_org(conn, org_id) do
      render(conn, :invoices, invoices: Billing.list_invoices(org.id))
    end
  end

  # ── Platform-admin: manage (gated by RequirePlatformAdmin in the pipeline) ───

  operation(:configure,
    summary: "Create a draft contract (platform-admin)",
    tags: ["Billing"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [org_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Contract terms", "application/json", Schemas.BillingContractRequest, required: true},
    responses: [
      ok: {"Contract", "application/json", Schemas.BillingContract},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Organization not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def configure(conn, %{"org_id" => org_id} = params) do
    with {:ok, org} <- org(org_id),
         attrs = Map.put(contract_attrs(params), :created_by, conn.assigns.current_user.id),
         {:ok, _contract} <- Billing.create_contract(org, attrs) do
      render(conn, :show, org: org, contract: Billing.get_contract(org.id))
    end
  end

  operation(:activate,
    summary: "Activate the org's latest draft contract (platform-admin)",
    tags: ["Billing"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [org_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Contract", "application/json", Schemas.BillingContract},
      conflict: {"An active contract already exists", "application/json", Schemas.Error},
      not_found: {"No draft contract", "application/json", Schemas.Error}
    ]
  )

  def activate(conn, %{"org_id" => org_id}) do
    with {:ok, org} <- org(org_id),
         {:ok, _contract} <- Billing.activate_latest_draft(org.id) do
      render(conn, :show, org: org, contract: Billing.get_contract(org.id))
    end
  end

  operation(:mark_paid,
    summary: "Mark an invoice paid (platform-admin)",
    tags: ["Billing"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      org_id: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Invoice", "application/json", Schemas.BillingInvoice},
      not_found: {"Invoice not found", "application/json", Schemas.Error}
    ]
  )

  def mark_paid(conn, %{"org_id" => org_id, "id" => id}) do
    with {:ok, _org} <- org(org_id),
         invoice when not is_nil(invoice) <- Billing.get_invoice(org_id, id),
         {:ok, paid} <- Billing.mark_invoice_paid(invoice) do
      render(conn, :invoice, invoice: paid)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  operation(:void,
    summary: "Void an invoice and claw back its funded credits (platform-admin)",
    tags: ["Billing"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      org_id: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true]
    ],
    responses: [
      ok: {"Invoice", "application/json", Schemas.BillingInvoice},
      not_found: {"Invoice not found", "application/json", Schemas.Error}
    ]
  )

  def void(conn, %{"org_id" => org_id, "id" => id}) do
    with {:ok, _org} <- org(org_id),
         invoice when not is_nil(invoice) <- Billing.get_invoice(org_id, id),
         {:ok, voided} <- Billing.void_invoice(invoice) do
      render(conn, :invoice, invoice: voided)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp org(org_id), do: Organizations.get_organization(org_id)

  defp admin_org(conn, org_id) do
    with {:ok, org} <- Organizations.get_organization(org_id) do
      if Organizations.admin?(org, conn.assigns.current_user.id),
        do: {:ok, org},
        else: {:error, :unauthorized}
    end
  end

  # Whitelisted string→atom contract attrs (amounts/dates/interval cast by the changeset).
  defp contract_attrs(params) do
    for key <- @manage_keys, Map.has_key?(params, key), into: %{} do
      {String.to_existing_atom(key), params[key]}
    end
  end
end
