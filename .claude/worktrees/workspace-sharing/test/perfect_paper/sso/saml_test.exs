defmodule PerfectPaper.SSO.SAMLTest do
  @moduledoc """
  Security tests for the real `esaml`-backed SAML adapter.

  All fixtures are generated in-process (`PerfectPaper.SamlFixtures`): an RSA
  keypair + a self-signed X.509 certificate (the "IdP"), and SAML Response XML
  signed with `xmerl_dsig`. NO live Entra / network is used.

  Critical assertions:
    * a validly-signed assertion → `{:ok, identity}` (email is a binary)
    * tampered / unsigned / DIFFERENT-key signed → `{:error, :invalid_assertion}`
    * expired (NotOnOrAfter in the past) → rejected
    * InResponseTo mismatch → rejected
    * an XXE payload → the external entity is NOT expanded + rejected
    * an envelope-signed (not assertion-signed) response → accepted
  """
  use ExUnit.Case, async: true

  alias PerfectPaper.SamlFixtures
  alias PerfectPaper.SSO.SAML

  @org_id "org-acme-1"
  @sp_entity_id "https://app.perfectpaper.test/sso/#{@org_id}"
  @callback_url "https://app.perfectpaper.test/sso/#{@org_id}/callback"
  @idp_sso_url "https://login.idp.test/saml2/sso"
  @request_id "_authnreq-12345"

  setup_all do
    {idp_pem, idp_key} = SamlFixtures.gen_self_signed()
    {other_pem, other_key} = SamlFixtures.gen_self_signed()
    %{idp_pem: idp_pem, idp_key: idp_key, other_pem: other_pem, other_key: other_key}
  end

  defp config(cert_pem) do
    %{
      organization_id: @org_id,
      saml_idp_sso_url: @idp_sso_url,
      saml_idp_cert: cert_pem,
      saml_sp_entity_id: @sp_entity_id,
      saml_sp_callback_url: @callback_url
    }
  end

  defp signed(opts) do
    SamlFixtures.signed_response(
      Keyword.merge(
        [
          callback_url: @callback_url,
          sp_entity_id: @sp_entity_id,
          request_id: @request_id
        ],
        opts
      )
    )
  end

  defp session_params, do: %{request_id: @request_id}

  # ── authorize_url ───────────────────────────────────────────────────────────

  describe "authorize_url/2" do
    test "returns an IdP redirect URL carrying a SAMLRequest and a request_id", %{
      idp_pem: idp_pem
    } do
      assert {:ok, %{url: url, session_params: %{request_id: request_id}}} =
               SAML.authorize_url(config(idp_pem), %{})

      assert url =~ "login.idp.test"
      assert url =~ "SAMLRequest="
      assert is_binary(request_id)
      assert request_id != ""
    end
  end

  # ── callback: positive ──────────────────────────────────────────────────────

  describe "callback/3 — valid signed assertion" do
    test "returns {:ok, identity} with a binary email", %{idp_pem: idp_pem, idp_key: idp_key} do
      b64 = signed(cert_pem: idp_pem, signing_key: idp_key)

      assert {:ok, identity} =
               SAML.callback(config(idp_pem), %{"SAMLResponse" => b64}, session_params())

      assert is_binary(identity.email)
      assert identity.email == "alice@acme.test"
      assert identity.uid == "alice@acme.test"
      assert identity.email_verified == true
      assert identity.provider == "saml:#{@org_id}"
      assert identity.name == "Alice Tester"
    end

    test "accepts an envelope-signed response", %{idp_pem: idp_pem, idp_key: idp_key} do
      b64 = signed(cert_pem: idp_pem, signing_key: idp_key, sign: :envelope)

      assert {:ok, identity} =
               SAML.callback(config(idp_pem), %{"SAMLResponse" => b64}, session_params())

      assert identity.email == "alice@acme.test"
    end
  end

  # ── callback: negative (security-critical) ──────────────────────────────────

  describe "callback/3 — signature rejection (CRITICAL)" do
    test "rejects an UNSIGNED assertion", %{idp_pem: idp_pem, idp_key: idp_key} do
      b64 = signed(cert_pem: idp_pem, signing_key: idp_key, sign: :none)

      assert {:error, :invalid_assertion} =
               SAML.callback(config(idp_pem), %{"SAMLResponse" => b64}, session_params())
    end

    test "rejects an assertion signed by a DIFFERENT key (wrong cert)", %{
      idp_pem: idp_pem,
      other_pem: other_pem,
      other_key: other_key
    } do
      # Signed with the OTHER keypair, but the config trusts the IdP cert.
      b64 = signed(cert_pem: other_pem, signing_key: other_key)

      assert {:error, :invalid_assertion} =
               SAML.callback(config(idp_pem), %{"SAMLResponse" => b64}, session_params())
    end

    test "rejects a TAMPERED assertion (email changed after signing)", %{
      idp_pem: idp_pem,
      idp_key: idp_key
    } do
      b64 = signed(cert_pem: idp_pem, signing_key: idp_key, tamper: true)

      assert {:error, :invalid_assertion} =
               SAML.callback(config(idp_pem), %{"SAMLResponse" => b64}, session_params())
    end
  end

  describe "callback/3 — conditions / replay" do
    test "rejects an EXPIRED assertion (NotOnOrAfter in the past)", %{
      idp_pem: idp_pem,
      idp_key: idp_key
    } do
      b64 =
        signed(cert_pem: idp_pem, signing_key: idp_key, not_on_or_after: SamlFixtures.past_time())

      assert {:error, :invalid_assertion} =
               SAML.callback(config(idp_pem), %{"SAMLResponse" => b64}, session_params())
    end

    test "rejects an InResponseTo MISMATCH (replay defense)", %{
      idp_pem: idp_pem,
      idp_key: idp_key
    } do
      b64 = signed(cert_pem: idp_pem, signing_key: idp_key, request_id: "_some-other-request")

      assert {:error, :invalid_assertion} =
               SAML.callback(config(idp_pem), %{"SAMLResponse" => b64}, session_params())
    end
  end

  describe "callback/3 — XXE defense" do
    test "an XXE payload does NOT expand the external entity and is rejected", %{
      idp_pem: idp_pem
    } do
      # A classic XXE: an external entity that, if expanded, would read a local
      # file. With {:allow_entities, false} the parse refuses entity expansion.
      xxe = """
      <?xml version="1.0"?>
      <!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
      <saml2p:Response xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" \
      xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" Version="2.0" IssueInstant="2024-01-01T00:00:00Z">\
      <saml2:Issuer>&xxe;</saml2:Issuer>\
      <saml2p:Status><saml2p:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></saml2p:Status>\
      </saml2p:Response>
      """

      b64 = Base.encode64(xxe)

      # The parse refuses the entity → no file is read → rejected (no crash that
      # would leak file contents).
      assert {:error, :invalid_assertion} =
               SAML.callback(config(idp_pem), %{"SAMLResponse" => b64}, session_params())
    end

    test "rejects an oversized SAMLResponse before parsing", %{idp_pem: idp_pem} do
      huge = String.duplicate("A", 1_500_000)
      b64 = Base.encode64(huge)

      assert {:error, :invalid_assertion} =
               SAML.callback(config(idp_pem), %{"SAMLResponse" => b64}, session_params())
    end

    test "rejects non-base64 garbage", %{idp_pem: idp_pem} do
      assert {:error, :invalid_assertion} =
               SAML.callback(
                 config(idp_pem),
                 %{"SAMLResponse" => "!!!not base64!!!"},
                 session_params()
               )
    end
  end

  describe "callback/3 — bad config" do
    test "rejects when the IdP cert is not valid PEM", %{idp_pem: idp_pem, idp_key: idp_key} do
      bad = config("not a pem certificate")
      b64 = signed(cert_pem: idp_pem, signing_key: idp_key)

      assert {:error, :invalid_assertion} =
               SAML.callback(bad, %{"SAMLResponse" => b64}, session_params())
    end
  end
end
