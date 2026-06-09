defmodule PerfectPaper.SamlFixtures do
  @moduledoc """
  Test fixtures for the real `esaml`-backed SAML adapter.

  Generates, entirely in-process (NO network, NO openssl shell-out):

    * a self-signed RSA X.509 IdP certificate + its private key, via `:public_key`
    * SAML 2.0 Response XML signed with `xmerl_dsig` (assertion- or
      envelope-signed), using Entra's `saml2:`/`saml2p:` namespace prefixes,
      base64-encoded for the HTTP-POST binding

  Used by the SAML adapter unit tests and the SSO controller POST-callback test.
  """

  require Record

  Record.defrecordp(
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  @doc """
  Generates a fresh self-signed cert. Returns `{pem_binary, private_key}`.
  """
  @spec gen_self_signed() :: {binary(), tuple()}
  def gen_self_signed do
    private_key = :public_key.generate_key({:rsa, 2048, 65537})
    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}

    subject =
      {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, "test-idp"}}]]}

    validity =
      {:Validity, {:utcTime, ~c"200101000000Z"}, {:generalTime, ~c"99991231235959Z"}}

    spki =
      {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 2, 840, 113_549, 1, 1, 1}, :NULL},
       public_key}

    tbs =
      {:OTPTBSCertificate, :v3, 1,
       {:SignatureAlgorithm, {1, 2, 840, 113_549, 1, 1, 11}, :asn1_NOVALUE}, subject, validity,
       subject, spki, :asn1_NOVALUE, :asn1_NOVALUE, :asn1_NOVALUE}

    der = :public_key.pkix_sign(tbs, private_key)
    pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
    {pem, private_key}
  end

  @doc """
  Builds a base64-encoded, signed SAMLResponse for the HTTP-POST binding.

  Options:
    * `:cert_pem` (required)   - PEM cert embedded in the signature
    * `:signing_key` (required)- the RSA key to sign with
    * `:callback_url` (required) - the assertion Recipient (= SP consume URI)
    * `:sp_entity_id` (required) - the assertion Audience
    * `:email`         - NameID + email attribute (default "alice@acme.test")
    * `:request_id`    - the assertion InResponseTo (default "_authnreq-12345")
    * `:not_on_or_after` - SAML datetime string (default: 1h in the future)
    * `:sign`          - `:assertion` (default) | `:envelope` | `:none`
    * `:tamper`        - if true, mutate the email AFTER signing (breaks digest)
  """
  @spec signed_response(keyword()) :: binary()
  def signed_response(opts) do
    cert_pem = Keyword.fetch!(opts, :cert_pem)
    signing_key = Keyword.fetch!(opts, :signing_key)
    callback_url = Keyword.fetch!(opts, :callback_url)
    sp_entity_id = Keyword.fetch!(opts, :sp_entity_id)
    email = Keyword.get(opts, :email, "alice@acme.test")
    request_id = Keyword.get(opts, :request_id, "_authnreq-12345")
    not_on_or_after = Keyword.get(opts, :not_on_or_after, future_time())
    sign = Keyword.get(opts, :sign, :assertion)
    tamper = Keyword.get(opts, :tamper, false)

    [{:Certificate, cert_der, _} | _] = :public_key.pem_decode(cert_pem)

    xml = response_xml(email, not_on_or_after, request_id, callback_url, sp_entity_id)
    {doc, _} = :xmerl_scan.string(String.to_charlist(xml), namespace_conformant: true)

    signed_doc =
      case sign do
        :none ->
          doc

        :assertion ->
          assertion = find_element(doc, :"saml2:Assertion")
          signed_assertion = :xmerl_dsig.sign(assertion, signing_key, cert_der)
          replace_assertion(doc, signed_assertion)

        :envelope ->
          :xmerl_dsig.sign(doc, signing_key, cert_der)
      end

    exported = :xmerl.export([signed_doc], :xmerl_xml) |> :erlang.iolist_to_binary()

    exported =
      if tamper, do: String.replace(exported, email, "attacker@acme.test"), else: exported

    Base.encode64(exported)
  end

  @doc "A SAML datetime ~1h in the future."
  @spec future_time() :: String.t()
  def future_time do
    DateTime.utc_now()
    |> DateTime.add(3600, :second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/\.\d+/, "")
  end

  @doc "A SAML datetime ~1h in the past."
  @spec past_time() :: String.t()
  def past_time do
    DateTime.utc_now()
    |> DateTime.add(-3600, :second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/\.\d+/, "")
  end

  # ── private ──────────────────────────────────────────────────────────────

  defp response_xml(email, not_on_or_after, request_id, callback_url, sp_entity_id) do
    """
    <saml2p:Response xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" \
    xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" \
    Version="2.0" IssueInstant="2024-01-01T00:00:00Z" Destination="#{callback_url}">\
    <saml2:Issuer>https://login.idp.test/</saml2:Issuer>\
    <saml2p:Status><saml2p:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></saml2p:Status>\
    <saml2:Assertion Version="2.0" IssueInstant="2024-01-01T00:00:00Z" ID="_assertion-1">\
    <saml2:Issuer>https://login.idp.test/</saml2:Issuer>\
    <saml2:Subject>\
    <saml2:NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">#{email}</saml2:NameID>\
    <saml2:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">\
    <saml2:SubjectConfirmationData Recipient="#{callback_url}" \
    NotOnOrAfter="#{not_on_or_after}" InResponseTo="#{request_id}"/>\
    </saml2:SubjectConfirmation>\
    </saml2:Subject>\
    <saml2:Conditions NotBefore="2024-01-01T00:00:00Z" NotOnOrAfter="#{not_on_or_after}">\
    <saml2:AudienceRestriction><saml2:Audience>#{sp_entity_id}</saml2:Audience></saml2:AudienceRestriction>\
    </saml2:Conditions>\
    <saml2:AttributeStatement>\
    <saml2:Attribute Name="email"><saml2:AttributeValue>#{email}</saml2:AttributeValue></saml2:Attribute>\
    <saml2:Attribute Name="name"><saml2:AttributeValue>Alice Tester</saml2:AttributeValue></saml2:Attribute>\
    </saml2:AttributeStatement>\
    <saml2:AuthnStatement AuthnInstant="2024-01-01T00:00:00Z">\
    <saml2:AuthnContext>\
    <saml2:AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:Password</saml2:AuthnContextClassRef>\
    </saml2:AuthnContext></saml2:AuthnStatement>\
    </saml2:Assertion>\
    </saml2p:Response>\
    """
  end

  defp find_element(element, name) do
    if xmlElement(element, :name) == name do
      element
    else
      element
      |> xmlElement(:content)
      |> Enum.find_value(fn
        child when Record.is_record(child, :xmlElement) -> find_element(child, name)
        _ -> nil
      end)
    end
  end

  defp replace_assertion(doc, signed_assertion) do
    content =
      doc
      |> xmlElement(:content)
      |> Enum.map(fn child ->
        if Record.is_record(child, :xmlElement) and
             xmlElement(child, :name) == :"saml2:Assertion" do
          signed_assertion
        else
          child
        end
      end)

    xmlElement(doc, content: content)
  end
end
