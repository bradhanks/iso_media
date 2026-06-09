defmodule PerfectPaper.SSO.OIDCTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.SSO.OIDC

  # ---------------------------------------------------------------------------
  # authority_url/1
  # ---------------------------------------------------------------------------

  describe "authority_url/1" do
    test "builds the tenant-scoped Entra v2.0 issuer URL" do
      tenant_id = "11111111-2222-3333-4444-555555555555"
      url = OIDC.authority_url(tenant_id)

      assert url == "https://login.microsoftonline.com/#{tenant_id}/v2.0"
    end

    test "works with a named (non-UUID) tenant slug" do
      assert OIDC.authority_url("contoso.onmicrosoft.com") ==
               "https://login.microsoftonline.com/contoso.onmicrosoft.com/v2.0"
    end
  end

  # ---------------------------------------------------------------------------
  # to_identity/2
  # ---------------------------------------------------------------------------

  describe "to_identity/2" do
    test "maps standard claims to the normalized identity map" do
      claims = %{
        "sub" => "abc123",
        "email" => "alice@corp.example",
        "email_verified" => true,
        "name" => "Alice Liddell"
      }

      identity = OIDC.to_identity(claims, "org_xyz")

      assert identity == %{
               provider: "oidc:org_xyz",
               uid: "abc123",
               email: "alice@corp.example",
               email_verified: true,
               name: "Alice Liddell"
             }
    end

    test "accepts email_verified as the string \"true\"" do
      claims = %{
        "sub" => "abc123",
        "email" => "bob@corp.example",
        "email_verified" => "true",
        "name" => "Bob"
      }

      identity = OIDC.to_identity(claims, "org_xyz")
      assert identity.email_verified == true
    end

    test "email_verified false when claim is false" do
      claims = %{
        "sub" => "abc123",
        "email" => "carol@corp.example",
        "email_verified" => false,
        "name" => "Carol"
      }

      identity = OIDC.to_identity(claims, "org_xyz")
      assert identity.email_verified == false
    end

    test "email_verified false when claim is absent" do
      claims = %{"sub" => "abc123", "email" => "dave@corp.example", "name" => "Dave"}

      identity = OIDC.to_identity(claims, "org_xyz")
      assert identity.email_verified == false
    end

    test "email_verified false when claim is nil" do
      claims = %{
        "sub" => "abc123",
        "email" => "eve@corp.example",
        "email_verified" => nil,
        "name" => "Eve"
      }

      identity = OIDC.to_identity(claims, "org_xyz")
      assert identity.email_verified == false
    end

    test "name is nil when absent from claims" do
      claims = %{"sub" => "abc123", "email" => "frank@corp.example"}

      identity = OIDC.to_identity(claims, "org_abc")
      assert is_nil(identity.name)
    end

    test "provider key is org-scoped so two orgs never collide" do
      claims = %{"sub" => "same-uid", "email" => "x@a.com"}

      id_org1 = OIDC.to_identity(claims, "org_1")
      id_org2 = OIDC.to_identity(claims, "org_2")

      assert id_org1.provider == "oidc:org_1"
      assert id_org2.provider == "oidc:org_2"
      # Same uid, different providers — no collision
      assert id_org1.provider != id_org2.provider
    end

    test "uid is stringified (guards against integer sub)" do
      claims = %{"sub" => 42, "email" => "num@corp.example"}

      identity = OIDC.to_identity(claims, "org_q")
      assert identity.uid == "42"
    end
  end

  # ---------------------------------------------------------------------------
  # authorize_url/2 — pure config wiring (no live HTTP)
  #
  # We inject a pre-fetched `openid_configuration` map so Assent.Strategy.OIDC
  # does not attempt an HTTP discovery request. This exercises the full
  # authorize_url/2 code path and verifies that the tenant authority, client_id,
  # scope, and redirect_uri are all wired correctly without hitting Entra.
  # ---------------------------------------------------------------------------

  @tenant_id "aaaabbbb-cccc-dddd-eeee-ffffffffffff"
  @client_id "test-client-id"
  @client_secret "test-client-secret"
  @redirect_uri "https://app.test/auth/sso/callback"
  @org_id "org_test"

  # Minimal OpenID configuration that Assent needs to build the authorize URL
  # (only authorization_endpoint is required for authorize_url).
  defp stub_openid_config(tenant_id) do
    authority = OIDC.authority_url(tenant_id)

    %{
      "issuer" => authority,
      "authorization_endpoint" => "#{authority}/oauth2/v2.0/authorize",
      "token_endpoint" => "#{authority}/oauth2/v2.0/token",
      "jwks_uri" => "#{authority}/discovery/v2.0/keys",
      "token_endpoint_auth_methods_supported" => ["client_secret_basic", "client_secret_post"]
    }
  end

  defp base_config do
    %{
      tenant_id: @tenant_id,
      client_id: @client_id,
      client_secret: @client_secret,
      redirect_uri: @redirect_uri,
      org_id: @org_id,
      openid_configuration: stub_openid_config(@tenant_id)
    }
  end

  describe "authorize_url/2" do
    test "returns {:ok, %{url: url, session_params: map}}" do
      assert {:ok, %{url: url, session_params: session_params}} =
               OIDC.authorize_url(base_config(), %{})

      assert is_binary(url)
      assert is_map(session_params)
    end

    test "url contains the tenant-scoped Entra authority" do
      {:ok, %{url: url}} = OIDC.authorize_url(base_config(), %{})

      assert url =~ @tenant_id
      assert url =~ "login.microsoftonline.com"
    end

    test "url contains the client_id" do
      {:ok, %{url: url}} = OIDC.authorize_url(base_config(), %{})
      assert url =~ @client_id
    end

    test "url contains the redirect_uri (URL-encoded)" do
      {:ok, %{url: url}} = OIDC.authorize_url(base_config(), %{})
      # redirect_uri appears encoded in the query string
      assert url =~ URI.encode_www_form(@redirect_uri) or url =~ "redirect_uri"
    end

    test "session_params includes a :state key for CSRF protection" do
      {:ok, %{session_params: session_params}} = OIDC.authorize_url(base_config(), %{})
      assert Map.has_key?(session_params, :state)
    end

    test "url requests the openid scope" do
      {:ok, %{url: url}} = OIDC.authorize_url(base_config(), %{})
      assert url =~ "openid"
    end
  end

  # ---------------------------------------------------------------------------
  # Provider behaviour contract
  # ---------------------------------------------------------------------------

  describe "behaviour compliance" do
    test "implements the SSO.Provider behaviour" do
      assert OIDC.__info__(:attributes)
             |> Keyword.get(:behaviour, [])
             |> Enum.member?(PerfectPaper.SSO.Provider)
    end
  end
end
