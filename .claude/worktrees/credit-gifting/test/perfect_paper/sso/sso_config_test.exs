defmodule PerfectPaper.SSO.SsoConfigTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.SSO.SsoConfig

  test "requires organization_id, protocol, email_domain" do
    cs = SsoConfig.changeset(%SsoConfig{}, %{})
    refute cs.valid?
    e = errors_on(cs)

    assert Map.has_key?(e, :organization_id) and Map.has_key?(e, :protocol) and
             Map.has_key?(e, :email_domain)
  end

  test "oidc requires tenant_id/client_id/client_secret" do
    cs =
      SsoConfig.changeset(%SsoConfig{}, %{
        organization_id: Ecto.UUID.generate(),
        protocol: :oidc,
        email_domain: "acme.test"
      })

    refute cs.valid?
    e = errors_on(cs)

    assert Map.has_key?(e, :oidc_tenant_id) and Map.has_key?(e, :oidc_client_id) and
             Map.has_key?(e, :oidc_client_secret)
  end

  test "saml requires idp_entity_id/idp_sso_url/idp_cert" do
    cs =
      SsoConfig.changeset(%SsoConfig{}, %{
        organization_id: Ecto.UUID.generate(),
        protocol: :saml,
        email_domain: "acme.test"
      })

    refute cs.valid?
    e = errors_on(cs)

    assert Map.has_key?(e, :saml_idp_entity_id) and Map.has_key?(e, :saml_idp_sso_url) and
             Map.has_key?(e, :saml_idp_cert)
  end

  test "rejects public/free email domains" do
    cs =
      SsoConfig.changeset(%SsoConfig{}, %{
        organization_id: Ecto.UUID.generate(),
        protocol: :oidc,
        email_domain: "gmail.com",
        oidc_tenant_id: "t",
        oidc_client_id: "c",
        oidc_client_secret: "s"
      })

    refute cs.valid?
    assert Map.has_key?(errors_on(cs), :email_domain)
  end

  test "lowercases email_domain and accepts a valid oidc config" do
    cs =
      SsoConfig.changeset(%SsoConfig{}, %{
        organization_id: Ecto.UUID.generate(),
        protocol: :oidc,
        email_domain: "ACME.test",
        oidc_tenant_id: "t",
        oidc_client_id: "c",
        oidc_client_secret: "s"
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :email_domain) == "acme.test"
  end

  test "does not cast domain_verified or enabled" do
    cs =
      SsoConfig.changeset(%SsoConfig{}, %{
        organization_id: Ecto.UUID.generate(),
        protocol: :oidc,
        email_domain: "acme.test",
        oidc_tenant_id: "t",
        oidc_client_id: "c",
        oidc_client_secret: "s",
        domain_verified: true,
        enabled: true
      })

    assert cs.valid?
    refute Map.has_key?(cs.changes, :domain_verified)
    refute Map.has_key?(cs.changes, :enabled)
  end

  # Fix A — domain sanitization tests
  test "strips leading @ from email_domain" do
    cs =
      SsoConfig.changeset(%SsoConfig{}, %{
        organization_id: Ecto.UUID.generate(),
        protocol: :oidc,
        email_domain: "@Company.com ",
        oidc_tenant_id: "t",
        oidc_client_id: "c",
        oidc_client_secret: "s"
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :email_domain) == "company.com"
  end

  test "strips trailing slash from email_domain" do
    cs =
      SsoConfig.changeset(%SsoConfig{}, %{
        organization_id: Ecto.UUID.generate(),
        protocol: :oidc,
        email_domain: "company.com/",
        oidc_tenant_id: "t",
        oidc_client_id: "c",
        oidc_client_secret: "s"
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :email_domain) == "company.com"
  end
end
