defmodule PerfectPaperWeb.Api.SsoController do
  @moduledoc """
  REST endpoints for managing an organization's enterprise SSO configuration
  (OIDC / SAML), domain verification, and the enable/disable gate.

  Org-admin gated: every action loads the org by `:org_id`, returns 404 when the
  org does not exist, and 403 when the caller is not an admin of it. Secret
  material (OIDC client secret, SAML IdP certificate) is NEVER returned — see
  `PerfectPaperWeb.Api.SsoJSON`.

  This is the management surface (`PerfectPaperWeb.Api.SsoController`), distinct
  from the public sign-in flow in `PerfectPaperWeb.SsoController`.
  """
  use PerfectPaperWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PerfectPaper.{Authz, Organizations, SSO}
  alias PerfectPaperWeb.Api.Schemas

  action_fallback PerfectPaperWeb.Api.FallbackController

  # ── Operations ─────────────────────────────────────────────────────────────

  operation(:show,
    summary: "Fetch the SSO configuration for an organization (secrets redacted)",
    tags: ["SSO"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      org_id: [in: :path, description: "Organization id", type: :string, required: true]
    ],
    responses: [
      ok: {"SSO configuration", "application/json", Schemas.SsoConfigResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Organization not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"org_id" => org_id}) do
    with {:ok, org} <- admin_org(conn, org_id) do
      render(conn, :show, config: SSO.get_config(org))
    end
  end

  operation(:configure,
    summary: "Create or update an organization's SSO configuration",
    tags: ["SSO"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      org_id: [in: :path, description: "Organization id", type: :string, required: true]
    ],
    request_body:
      {"SSO credential attributes", "application/json", Schemas.SsoConfigRequest, required: true},
    responses: [
      ok: {"Updated SSO configuration", "application/json", Schemas.SsoConfigResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Organization not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def configure(conn, %{"org_id" => org_id} = params) do
    with {:ok, org} <- admin_org(conn, org_id),
         {:ok, config} <- SSO.configure_sso(org, scope(conn), SSO.config_attrs(params)) do
      render(conn, :show, config: config)
    end
  end

  operation(:verify_domain,
    summary: "Mark the organization's SSO email domain as verified",
    tags: ["SSO"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      org_id: [in: :path, description: "Organization id", type: :string, required: true]
    ],
    responses: [
      ok: {"Verified SSO configuration", "application/json", Schemas.SsoConfigResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Organization or SSO config not found", "application/json", Schemas.Error}
    ]
  )

  def verify_domain(conn, %{"org_id" => org_id}) do
    with {:ok, org} <- admin_org(conn, org_id),
         {:ok, config} <- SSO.verify_domain(org, scope(conn)) do
      render(conn, :show, config: config)
    end
  end

  operation(:enable,
    summary: "Enable or disable SSO for an organization",
    tags: ["SSO"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      org_id: [in: :path, description: "Organization id", type: :string, required: true]
    ],
    request_body: {"Enable flag", "application/json", Schemas.SsoEnableRequest, required: true},
    responses: [
      ok: {"Updated SSO configuration", "application/json", Schemas.SsoConfigResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Organization or SSO config not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Domain not verified", "application/json", Schemas.Error}
    ]
  )

  def enable(conn, %{"org_id" => org_id} = params) do
    enabled? = truthy(params["enabled"])

    with {:ok, org} <- admin_org(conn, org_id),
         {:ok, config} <- SSO.enable_sso(org, scope(conn), enabled?) do
      render(conn, :show, config: config)
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  # Builds the enriched authorization scope for the current user.
  @spec scope(Plug.Conn.t()) :: PerfectPaper.Accounts.Scope.t()
  defp scope(conn), do: Authz.load_subject(conn.assigns.current_user)

  # Loads the org by id and gates on org-admin status.
  #
  # Unknown org → `{:error, :not_found}` (→ 404).
  # Caller is not an admin of the org → `{:error, :unauthorized}` (→ 403).
  @spec admin_org(Plug.Conn.t(), binary()) ::
          {:ok, PerfectPaper.Organizations.Organization.t()}
          | {:error, :not_found | :unauthorized}
  defp admin_org(conn, org_id) do
    with {:ok, org} <- Organizations.get_organization(org_id) do
      if Organizations.admin?(org, conn.assigns.current_user.id) do
        {:ok, org}
      else
        {:error, :unauthorized}
      end
    end
  end

  # Coerces an incoming JSON value into a boolean for the enable toggle.
  # Defensive input adaptation: the OpenAPI schema requires `enabled` to be a
  # boolean, so a missing/invalid value here only ever arrives if validation is
  # bypassed; we treat anything that is not an explicit true as false.
  @spec truthy(term()) :: boolean()
  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false
end
