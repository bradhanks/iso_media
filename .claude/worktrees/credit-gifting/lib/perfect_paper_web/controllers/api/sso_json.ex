defmodule PerfectPaperWeb.Api.SsoJSON do
  @moduledoc """
  Renders an org's SSO configuration as JSON for the management REST API.

  Secret material is NEVER serialized: the OIDC client secret and the SAML IdP
  certificate are replaced by boolean `*_set` flags that report only whether a
  value is currently stored. The raw secret string never leaves the context.
  """

  alias PerfectPaper.SSO.SsoConfig

  @doc """
  Renders a single SSO config in the standard `{data: ...}` envelope.

  When `config` is `nil` (no SSO configured yet), emits `{configured: false}`
  with all other fields null — a 200 response, consistent with how the surface
  treats "not yet configured" as a valid, queryable state rather than a 404.
  """
  def show(%{config: %SsoConfig{} = config}), do: %{data: config(config)}
  def show(%{config: nil}), do: %{data: not_configured()}

  defp config(%SsoConfig{} = c) do
    %{
      configured: true,
      protocol: c.protocol,
      email_domain: c.email_domain,
      domain_verified: c.domain_verified,
      enabled: c.enabled,
      oidc_tenant_id: c.oidc_tenant_id,
      oidc_client_id: c.oidc_client_id,
      oidc_client_secret_set: present?(c.oidc_client_secret),
      saml_idp_entity_id: c.saml_idp_entity_id,
      saml_idp_sso_url: c.saml_idp_sso_url,
      saml_idp_cert_set: present?(c.saml_idp_cert),
      saml_sp_entity_id: c.saml_sp_entity_id
    }
  end

  defp not_configured do
    %{
      configured: false,
      protocol: nil,
      email_domain: nil,
      domain_verified: false,
      enabled: false,
      oidc_tenant_id: nil,
      oidc_client_id: nil,
      oidc_client_secret_set: false,
      saml_idp_entity_id: nil,
      saml_idp_sso_url: nil,
      saml_idp_cert_set: false,
      saml_sp_entity_id: nil
    }
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: true
  defp present?(_), do: false
end
