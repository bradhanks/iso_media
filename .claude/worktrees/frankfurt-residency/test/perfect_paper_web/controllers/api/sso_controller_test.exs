defmodule PerfectPaperWeb.Api.SsoControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  alias PerfectPaper.{Authz, SSO}

  @oidc_attrs %{
    "protocol" => "oidc",
    "email_domain" => "acme.test",
    "oidc_tenant_id" => "tenant-abc",
    "oidc_client_id" => "client-123",
    "oidc_client_secret" => "super-secret-value"
  }

  @saml_secret "-----BEGIN CERTIFICATE-----TOPSECRETCERT-----END CERTIFICATE-----"

  # ---------------------------------------------------------------------------
  # Setup: authed admin who owns an org
  # ---------------------------------------------------------------------------

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(user, "ci")
    org = organization_fixture(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user, org: org}
  end

  defp configure(org, user) do
    scope = Authz.load_subject(user)

    {:ok, config} =
      SSO.configure_sso(org, scope, %{
        protocol: :oidc,
        email_domain: "acme.test",
        oidc_tenant_id: "tenant-abc",
        oidc_client_id: "client-123",
        oidc_client_secret: "super-secret-value"
      })

    config
  end

  # ---------------------------------------------------------------------------
  # show
  # ---------------------------------------------------------------------------

  describe "GET /api/orgs/:org_id/sso" do
    test "returns not-configured when no config exists", %{conn: conn, org: org} do
      resp = conn |> get(~p"/api/orgs/#{org.id}/sso") |> json_response(200)
      assert resp["data"]["configured"] == false
    end

    test "returns the redacted config when one exists", %{conn: conn, org: org, user: user} do
      configure(org, user)
      resp = conn |> get(~p"/api/orgs/#{org.id}/sso") |> json_response(200)
      data = resp["data"]

      assert data["configured"] == true
      assert data["protocol"] == "oidc"
      assert data["email_domain"] == "acme.test"
      assert data["oidc_client_id"] == "client-123"
      assert data["oidc_client_secret_set"] == true
    end

    test "never exposes the raw OIDC client secret", %{conn: conn, org: org, user: user} do
      configure(org, user)
      body = conn |> get(~p"/api/orgs/#{org.id}/sso") |> response(200)
      refute body =~ "super-secret-value"
      refute body =~ "oidc_client_secret\""
    end

    test "404 for an unknown org", %{conn: conn} do
      resp = conn |> get(~p"/api/orgs/#{Ecto.UUID.generate()}/sso") |> json_response(404)
      assert resp["detail"] == "Not found"
    end

    test "404 (not 500) for a malformed, non-UUID org id", %{conn: conn} do
      resp = conn |> get("/api/orgs/not-a-uuid/sso") |> json_response(404)
      assert resp["detail"] == "Not found"
    end

    test "403 for a non-admin user", %{org: org, user: user} do
      configure(org, user)
      other = user_fixture()
      {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(other, "ci")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("accept", "application/json")

      resp = conn |> get(~p"/api/orgs/#{org.id}/sso") |> json_response(403)
      assert resp["detail"] == "Forbidden"
    end
  end

  # ---------------------------------------------------------------------------
  # configure
  # ---------------------------------------------------------------------------

  describe "PUT /api/orgs/:org_id/sso" do
    test "configures OIDC SSO and returns the redacted config", %{conn: conn, org: org} do
      resp = conn |> put(~p"/api/orgs/#{org.id}/sso", @oidc_attrs) |> json_response(200)
      data = resp["data"]
      assert data["protocol"] == "oidc"
      assert data["oidc_client_secret_set"] == true
    end

    test "never echoes the submitted secret back", %{conn: conn, org: org} do
      body = conn |> put(~p"/api/orgs/#{org.id}/sso", @oidc_attrs) |> response(200)
      refute body =~ "super-secret-value"
    end

    test "configures SAML SSO without leaking the cert", %{conn: conn, org: org} do
      attrs = %{
        "protocol" => "saml",
        "email_domain" => "saml.test",
        "saml_idp_entity_id" => "https://idp.saml.test/entity",
        "saml_idp_sso_url" => "https://idp.saml.test/sso",
        "saml_idp_cert" => @saml_secret
      }

      body = conn |> put(~p"/api/orgs/#{org.id}/sso", attrs) |> response(200)
      resp = Jason.decode!(body)
      assert resp["data"]["saml_idp_cert_set"] == true
      refute body =~ "TOPSECRETCERT"
    end

    test "422 on invalid attrs (public email domain)", %{conn: conn, org: org} do
      attrs = Map.put(@oidc_attrs, "email_domain", "gmail.com")
      resp = conn |> put(~p"/api/orgs/#{org.id}/sso", attrs) |> json_response(422)
      assert resp["detail"] != nil
    end

    test "403 for a non-admin user", %{org: org} do
      other = user_fixture()
      {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(other, "ci")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("accept", "application/json")

      resp = conn |> put(~p"/api/orgs/#{org.id}/sso", @oidc_attrs) |> json_response(403)
      assert resp["detail"] == "Forbidden"
    end
  end

  # ---------------------------------------------------------------------------
  # verify_domain
  # ---------------------------------------------------------------------------

  describe "POST /api/orgs/:org_id/sso/verify-domain" do
    test "marks the domain verified", %{conn: conn, org: org, user: user} do
      configure(org, user)
      resp = conn |> post(~p"/api/orgs/#{org.id}/sso/verify-domain") |> json_response(200)
      assert resp["data"]["domain_verified"] == true
    end

    test "404 when no config exists yet", %{conn: conn, org: org} do
      resp = conn |> post(~p"/api/orgs/#{org.id}/sso/verify-domain") |> json_response(404)
      assert resp["detail"] == "Not found"
    end
  end

  # ---------------------------------------------------------------------------
  # enable
  # ---------------------------------------------------------------------------

  describe "POST /api/orgs/:org_id/sso/enable" do
    test "enables SSO after the domain is verified", %{conn: conn, org: org, user: user} do
      configure(org, user)
      SSO.verify_domain(org, Authz.load_subject(user))

      resp =
        conn
        |> post(~p"/api/orgs/#{org.id}/sso/enable", %{"enabled" => true})
        |> json_response(200)

      assert resp["data"]["enabled"] == true
    end

    test "enabling before verification returns a clean 422 (not 500)", %{
      conn: conn,
      org: org,
      user: user
    } do
      configure(org, user)
      resp = conn |> post(~p"/api/orgs/#{org.id}/sso/enable", %{"enabled" => true})
      assert resp.status == 422
      body = json_response(resp, 422)
      assert body["detail"] =~ "verified"
    end

    test "disables SSO", %{conn: conn, org: org, user: user} do
      configure(org, user)
      scope = Authz.load_subject(user)
      SSO.verify_domain(org, scope)
      SSO.enable_sso(org, scope, true)

      resp =
        conn
        |> post(~p"/api/orgs/#{org.id}/sso/enable", %{"enabled" => false})
        |> json_response(200)

      assert resp["data"]["enabled"] == false
    end

    test "403 for a non-admin user", %{org: org, user: user} do
      configure(org, user)
      other = user_fixture()
      {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(other, "ci")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("accept", "application/json")

      resp =
        conn
        |> post(~p"/api/orgs/#{org.id}/sso/enable", %{"enabled" => true})
        |> json_response(403)

      assert resp["detail"] == "Forbidden"
    end
  end
end
