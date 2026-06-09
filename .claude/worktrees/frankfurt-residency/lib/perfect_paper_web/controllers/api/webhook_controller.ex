defmodule PerfectPaperWeb.Api.WebhookController do
  @moduledoc """
  REST endpoints for managing webhook endpoints (CRUD + secret rotation +
  delivery log). Org-admin gated: every action resolves the caller's
  administering org and delegates to the `Webhooks` context.

  Secret is returned **only** from `create` and `rotate_secret` — never from
  index, show, or update.
  """
  use PerfectPaperWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PerfectPaper.{Authz, Organizations, Webhooks}
  alias PerfectPaperWeb.Api.Schemas

  action_fallback PerfectPaperWeb.Api.FallbackController

  # ── Operations ─────────────────────────────────────────────────────────────

  operation(:index,
    summary: "List webhook endpoints for the caller's org",
    tags: ["Webhooks"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    responses: [
      ok: {"List of webhook endpoints", "application/json", Schemas.WebhookEndpointListResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    with {:ok, org} <- caller_org(conn),
         {:ok, endpoints} <- Webhooks.list_endpoints(org, scope(conn)) do
      render(conn, :index, endpoints: endpoints)
    end
  end

  operation(:create,
    summary: "Create a webhook endpoint",
    tags: ["Webhooks"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    request_body:
      {"Endpoint attributes", "application/json", Schemas.WebhookEndpointRequest, required: true},
    responses: [
      created:
        {"Created endpoint with secret", "application/json", Schemas.WebhookEndpointResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    with {:ok, org} <- caller_org(conn),
         {:ok, endpoint} <- Webhooks.create_endpoint(org, scope(conn), params) do
      conn
      |> put_status(:created)
      |> render(:show, endpoint: endpoint, include_secret: true)
    end
  end

  operation(:show,
    summary: "Fetch a webhook endpoint",
    tags: ["Webhooks"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Endpoint id", type: :string, required: true]
    ],
    responses: [
      ok: {"Webhook endpoint", "application/json", Schemas.WebhookEndpointResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    with {:ok, endpoint} <- Webhooks.get_endpoint(id, scope(conn)) do
      render(conn, :show, endpoint: endpoint)
    end
  end

  operation(:update,
    summary: "Update a webhook endpoint",
    tags: ["Webhooks"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Endpoint id", type: :string, required: true]
    ],
    request_body:
      {"Fields to update", "application/json", Schemas.WebhookEndpointRequest, required: true},
    responses: [
      ok: {"Updated endpoint", "application/json", Schemas.WebhookEndpointResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    s = scope(conn)

    with {:ok, endpoint} <- Webhooks.get_endpoint(id, s),
         {:ok, updated} <- Webhooks.update_endpoint(endpoint, s, Map.drop(params, ["id"])) do
      render(conn, :show, endpoint: updated)
    end
  end

  operation(:delete,
    summary: "Delete a webhook endpoint",
    tags: ["Webhooks"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Endpoint id", type: :string, required: true]
    ],
    responses: [
      no_content: "Endpoint deleted",
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    s = scope(conn)

    with {:ok, endpoint} <- Webhooks.get_endpoint(id, s),
         {:ok, _} <- Webhooks.delete_endpoint(endpoint, s) do
      send_resp(conn, :no_content, "")
    end
  end

  operation(:rotate_secret,
    summary: "Rotate the signing secret for a webhook endpoint",
    tags: ["Webhooks"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Endpoint id", type: :string, required: true]
    ],
    responses: [
      ok: {"Endpoint with new secret", "application/json", Schemas.WebhookEndpointResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def rotate_secret(conn, %{"id" => id}) do
    s = scope(conn)

    with {:ok, endpoint} <- Webhooks.get_endpoint(id, s),
         {:ok, updated} <- Webhooks.rotate_secret(endpoint, s) do
      render(conn, :show, endpoint: updated, include_secret: true)
    end
  end

  operation(:deliveries,
    summary: "List delivery attempts for a webhook endpoint",
    tags: ["Webhooks"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Endpoint id", type: :string, required: true]
    ],
    responses: [
      ok: {"List of deliveries", "application/json", Schemas.WebhookDeliveryListResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def deliveries(conn, %{"id" => id}) do
    s = scope(conn)

    with {:ok, endpoint} <- Webhooks.get_endpoint(id, s),
         {:ok, deliveries} <- Webhooks.list_deliveries(endpoint, s) do
      render(conn, :deliveries, deliveries: deliveries)
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  # Builds the enriched authorization scope for the current user.
  @spec scope(Plug.Conn.t()) :: PerfectPaper.Accounts.Scope.t()
  defp scope(conn), do: Authz.load_subject(conn.assigns.current_user)

  # Resolves the org the caller administers.
  #
  # If the user administers NO org → `{:error, :unauthorized}` (→ 403).
  # If MORE THAN ONE: accepts an optional `organization_id` param to
  # disambiguate; otherwise uses the first and logs a TODO.
  # TODO(webhooks): multi-org disambiguation — require organization_id param
  # when the user is admin of more than one org.
  @spec caller_org(Plug.Conn.t()) ::
          {:ok, PerfectPaper.Organizations.Organization.t()} | {:error, :unauthorized}
  defp caller_org(conn) do
    user_id = conn.assigns.current_user.id

    case Organizations.admin_orgs(user_id) do
      [] ->
        {:error, :unauthorized}

      [org] ->
        {:ok, org}

      orgs ->
        org_id = conn.params["organization_id"]

        if org_id do
          case Enum.find(orgs, &(&1.id == org_id)) do
            nil -> {:error, :unauthorized}
            org -> {:ok, org}
          end
        else
          # TODO(webhooks): multi-org disambiguation
          {:ok, hd(orgs)}
        end
    end
  end
end
