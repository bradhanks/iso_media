defmodule PerfectPaper.SSO.SAML do
  @moduledoc """
  Real, per-organization SAML 2.0 adapter for enterprise SSO via `esaml`.

  Implements `PerfectPaper.SSO.Provider`. This is the ONLY module in the app
  that references `esaml`, `xmerl`, or `:public_key` SAML specifics — everything
  above receives the normalized, atom-keyed `identity` map.

  ## Security model (see `docs/superpowers/plans/2026-06-03-entra-sso.md`)

    * **XXE-safe parse.** The POST `SAMLResponse` is attacker-controlled. We do
      NOT call `esaml_binding:decode_response/2` (it parses with no safe xmerl
      options). Instead we base64-decode ourselves (POST binding is base64 only,
      never inflated), enforce a max-size guard, and parse with
      `:xmerl_scan.string/2` passing `{:allow_entities, false}` — explicitly
      disabling entity expansion (XXE defense-in-depth, independent of the
      OTP-29 default) — plus `{:namespace_conformant, true}` so esaml's
      namespace-aware XPath matches Entra's `saml2:`/`saml2p:` prefixes. The
      PRE-PARSED document is handed to esaml.

    * **XSW (XML Signature Wrapping) defense.** Identity fields (NameID, email,
      name) are read ONLY from esaml's cryptographically-validated
      `#esaml_assertion{}` struct — never via raw XPath on the document.

    * **Signature validation is mandatory.** `esaml_sp:validate_assertion/2`
      verifies the enveloped XML signature against the org's pinned IdP
      certificate (via its SHA-256 fingerprint in `trusted_fingerprints`) and
      rejects unsigned, tampered, wrong-key, expired, or wrong-audience
      assertions. Baseline requires a signed assertion. (The /2 arity stubs
      esaml's duplicate-detection `dupe_fun` to always-ok, so esaml itself does
      NOT detect replayed assertions — see below.)

    * **Replay / InResponseTo.** The AuthnRequest ID minted in `authorize_url/2`
      is returned in `session_params[:request_id]` and persisted in the session.
      On callback we assert the validated assertion's `InResponseTo` equals the
      stored ID, rejecting any mismatch. Replay/duplicate-assertion defense
      relies SOLELY on this one-time, session-bound `InResponseTo` request-id
      check — not on esaml's `dupe_fun` (which the /2 arity stubs to always-ok).
      The stored request id is consumed once, so a replayed response fails the
      match.

  ## Config map keys (from `SSO.provider_config/1`)

    * `:organization_id`     - PerfectPaper org id (scopes the `provider` key)
    * `:saml_idp_sso_url`    - IdP SingleSignOnService URL (AuthnRequest target)
    * `:saml_idp_cert`       - IdP signing certificate, PEM text (pinned)
    * `:saml_sp_entity_id`   - this SP's entity id (the assertion `Audience`)
    * `:saml_sp_callback_url`- the ACS/Recipient URL (assertion `Recipient`);
                               optional — defaults from `:saml_sp_entity_id`

  All keys may be string- or atom-keyed; `fetch_key/3` accepts either.
  """

  @behaviour PerfectPaper.SSO.Provider

  require Record

  Record.defrecordp(
    :esaml_sp,
    Record.extract(:esaml_sp, from_lib: "esaml/include/esaml.hrl")
  )

  Record.defrecordp(
    :esaml_assertion,
    Record.extract(:esaml_assertion, from_lib: "esaml/include/esaml.hrl")
  )

  Record.defrecordp(
    :esaml_subject,
    Record.extract(:esaml_subject, from_lib: "esaml/include/esaml.hrl")
  )

  Record.defrecordp(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  # Reject any SAMLResponse whose decoded XML exceeds this many bytes before we
  # ever hand it to the parser. A guard against billion-laughs / huge-payload
  # resource-exhaustion attacks.
  @max_xml_bytes 1_000_000

  # ---------------------------------------------------------------------------
  # Provider behaviour
  # ---------------------------------------------------------------------------

  @doc """
  Builds a per-org SAML AuthnRequest and returns the IdP redirect URL.

  Constructs an `#esaml_sp{}` from the org's config (SP entity id as audience,
  the callback URL as the assertion recipient, the IdP cert pinned as a trusted
  fingerprint), generates an AuthnRequest XML element (esaml stamps a unique
  `ID`), and HTTP-Redirect-encodes it against the IdP SSO URL.

  Returns `{:ok, %{url: url, session_params: %{request_id: id}}}`. The
  `request_id` MUST be persisted and later matched against the response's
  `InResponseTo` (replay defense).
  """
  @impl true
  @spec authorize_url(map(), map()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  def authorize_url(config, _session_params) do
    with {:ok, sp} <- build_sp(config) do
      idp_url = fetch_key(config, :saml_idp_sso_url) |> to_string()
      authn_xml = :esaml_sp.generate_authn_request(String.to_charlist(idp_url), sp)
      request_id = extract_id(authn_xml)

      url =
        :esaml_binding.encode_http_redirect(
          String.to_charlist(idp_url),
          authn_xml,
          :undefined,
          <<>>
        )

      {:ok, %{url: to_string(url), session_params: %{request_id: request_id}}}
    end
  end

  @doc """
  Validates a SAML POST `SAMLResponse` and returns the normalized identity.

  Pipeline (fail-closed at every step):

    1. base64-decode (POST binding: NO inflate) + max-size guard
    2. XXE-safe parse (`{:allow_entities, false}`) → pre-parsed xmerl doc
    3. build the per-org SP (IdP cert pinned)
    4. `esaml_sp:validate_assertion/2` — signature + conditions + audience +
       recipient + freshness against the pinned cert (the /2 arity stubs
       esaml's duplicate-detection `dupe_fun` to always-ok)
    5. assert `InResponseTo` == `session_params[:request_id]` — the SOLE
       replay/duplicate-assertion defense (esaml's dupe_fun is not used)
    6. map the VALIDATED assertion → identity (charlist → binary throughout)

  Any failure returns `{:error, :invalid_assertion}`.
  """
  @impl true
  @spec callback(map(), map(), map()) ::
          {:ok, PerfectPaper.SSO.Provider.identity()} | {:error, term()}
  def callback(config, %{"SAMLResponse" => b64} = _params, session_params)
      when is_binary(b64) do
    with {:ok, xml_string} <- decode_response(b64),
         {:ok, xml_doc} <- parse_xml(xml_string),
         {:ok, assertion} <- validate(xml_doc, config),
         :ok <- check_in_response_to(assertion, session_params) do
      {:ok, to_identity(assertion, fetch_key(config, :organization_id))}
    else
      _ -> {:error, :invalid_assertion}
    end
  end

  def callback(_config, _params, _session_params), do: {:error, :invalid_assertion}

  # ---------------------------------------------------------------------------
  # Decode + XXE-safe parse (attacker-controlled input)
  # ---------------------------------------------------------------------------

  # POST binding: the SAMLResponse is base64 ONLY (never deflated). Inflating it
  # would crash zlib with :data_error. Guard the decoded size BEFORE parsing.
  @spec decode_response(binary()) :: {:ok, String.t()} | {:error, term()}
  defp decode_response(b64) do
    case Base.decode64(b64, ignore: :whitespace) do
      {:ok, xml} when byte_size(xml) <= @max_xml_bytes -> {:ok, xml}
      {:ok, _too_big} -> {:error, :saml_response_too_large}
      :error -> {:error, :invalid_base64}
    end
  end

  # XXE-safe parse. {:allow_entities, false} forbids entity expansion outright
  # (so an XXE/billion-laughs payload neither expands nor fetches anything);
  # {:namespace_conformant, true} makes namespace-aware XPath work so esaml
  # matches Entra's saml2:/saml2p: prefixes; {:quiet, true} suppresses stdout on
  # malformed XML. We hand the PRE-PARSED doc to esaml.
  @spec parse_xml(String.t()) :: {:ok, term()} | {:error, term()}
  defp parse_xml(xml_string) do
    xml_charlist = String.to_charlist(xml_string)

    try do
      {xml_doc, _rest} =
        :xmerl_scan.string(
          xml_charlist,
          allow_entities: false,
          namespace_conformant: true,
          quiet: true
        )

      {:ok, xml_doc}
    catch
      _kind, error -> {:error, {:xml_parse_failed, error}}
    end
  end

  # ---------------------------------------------------------------------------
  # esaml validation (signature / conditions / audience / recipient)
  # ---------------------------------------------------------------------------

  # Validates against the org's pinned cert. esaml ANDs `idp_signs_assertions`
  # and `idp_signs_envelopes` — so requiring both would reject a response that
  # signs only one location. To accept EITHER an assertion-signed OR an
  # envelope-signed response (while still requiring AT LEAST one valid signature
  # against the pinned cert), we try the assertion-signed SP first and fall back
  # to the envelope-signed SP. An unsigned/tampered/wrong-key response fails
  # BOTH modes → rejected. This never accepts an unsigned response.
  @spec validate(term(), map()) :: {:ok, term()} | {:error, term()}
  defp validate(xml_doc, config) do
    with {:ok, assertion_sp} <- build_sp(config, signs: :assertion),
         {:ok, envelope_sp} <- build_sp(config, signs: :envelope) do
      case run_validate(xml_doc, assertion_sp) do
        {:ok, assertion} -> {:ok, assertion}
        {:error, _} -> run_validate(xml_doc, envelope_sp)
      end
    end
  end

  @spec run_validate(term(), term()) :: {:ok, term()} | {:error, term()}
  defp run_validate(xml_doc, sp) do
    try do
      case :esaml_sp.validate_assertion(xml_doc, sp) do
        {:ok, assertion} -> {:ok, assertion}
        {:error, reason} -> {:error, reason}
      end
    catch
      _kind, reason -> {:error, {:validate_crash, reason}}
    end
  end

  # InResponseTo replay defense. The validated assertion's subject carries the
  # InResponseTo; it MUST equal the AuthnRequest ID we minted at redirect.
  @spec check_in_response_to(term(), map()) :: :ok | {:error, term()}
  defp check_in_response_to(assertion, session_params) do
    expected = session_params[:request_id] || session_params["request_id"]
    actual = assertion |> esaml_assertion(:subject) |> esaml_subject(:in_response_to)

    cond do
      is_nil(expected) -> {:error, :missing_request_id}
      List.to_string(actual) == to_string(expected) -> :ok
      true -> {:error, :in_response_to_mismatch}
    end
  end

  # ---------------------------------------------------------------------------
  # Identity mapping — XSW-safe: ONLY from the validated assertion struct
  # ---------------------------------------------------------------------------

  # esaml returns CHARLISTS for NameID, issuer, and every attribute key/value.
  # We convert ALL of them to binaries before building the identity, or
  # downstream sanitize_domain/case-ops crash and Ecto corrupts the column.
  @spec to_identity(term(), term()) :: PerfectPaper.SSO.Provider.identity()
  defp to_identity(assertion, org_id) do
    subject = esaml_assertion(assertion, :subject)
    name_id = subject |> esaml_subject(:name) |> List.to_string()

    attrs =
      assertion
      |> esaml_assertion(:attributes)
      |> Map.new(fn {k, v} -> {to_attr_key(k), to_attr_values(v)} end)

    email = attr(attrs, ["email", "emailaddress", "mail"]) || name_id_if_email(name_id)
    name = attr(attrs, ["name", "displayname", "givenname"])

    %{
      provider: "saml:#{org_id}",
      uid: name_id,
      email: email,
      # The trusted IdP asserted (and signed) this identity, so the email is
      # considered verified for the purposes of the JIT verified-domain guard.
      email_verified: true,
      name: name
    }
  end

  # esaml maps well-known SAML attribute names to atoms (e.g. :email), and
  # leaves unknown ones as charlists. Normalize both to lowercase binary keys.
  defp to_attr_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_attr_key(k) when is_list(k), do: k |> List.to_string() |> String.downcase()
  defp to_attr_key(k) when is_binary(k), do: String.downcase(k)

  defp to_attr_values(values) when is_list(values) do
    # A SAML attribute value is itself a charlist; a multi-value attribute is a
    # list of charlists. esaml gives us a list of charlists OR a single charlist.
    case values do
      [h | _] when is_integer(h) -> [List.to_string(values)]
      _ -> Enum.map(values, &List.to_string/1)
    end
  end

  defp to_attr_values(value) when is_binary(value), do: [value]

  # First non-nil attribute value for any of the candidate keys.
  defp attr(attrs, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(attrs, key) do
        [first | _] -> first
        _ -> nil
      end
    end)
  end

  # Entra commonly sends the email as the NameID (emailAddress format). If no
  # email attribute was present but the NameID looks like an email, use it.
  defp name_id_if_email(name_id) do
    if String.contains?(name_id, "@"), do: name_id, else: nil
  end

  # ---------------------------------------------------------------------------
  # Per-org SP construction (PEM → DER → pinned fingerprint)
  # ---------------------------------------------------------------------------

  # Builds the per-org esaml SP record. The SP does NOT sign requests (no key),
  # so esaml leaves request-signing off. The IdP's signing cert is pinned by its
  # SHA-256 fingerprint in trusted_fingerprints — this is what makes a signature
  # from any OTHER key (different cert) fail with cert_not_accepted.
  @spec build_sp(map(), keyword()) :: {:ok, term()} | {:error, term()}
  defp build_sp(config, opts \\ []) do
    with {:ok, der} <- pem_to_der(fetch_key(config, :saml_idp_cert)) do
      entity_id = fetch_key(config, :saml_sp_entity_id) |> to_string()
      callback_url = fetch_key(config, :saml_sp_callback_url) || entity_id
      fingerprint = {:sha256, :crypto.hash(:sha256, der)}

      # `signs:` selects WHERE the signature must be. esaml ANDs these flags, so
      # exactly one is enabled per SP; `validate/2` tries assertion then envelope.
      {signs_assertions, signs_envelopes} =
        case Keyword.get(opts, :signs, :assertion) do
          :assertion -> {true, false}
          :envelope -> {false, true}
        end

      sp =
        esaml_sp(
          entity_id: String.to_charlist(entity_id),
          consume_uri: String.to_charlist(to_string(callback_url)),
          metadata_uri: String.to_charlist(entity_id),
          idp_signs_assertions: signs_assertions,
          idp_signs_envelopes: signs_envelopes,
          trusted_fingerprints: [fingerprint]
        )

      {:ok, sp}
    end
  end

  # saml_idp_cert is stored as PEM text; esaml/:public_key need DER. Passing raw
  # PEM into :public_key.verify would :badmatch deep inside.
  @spec pem_to_der(term()) :: {:ok, binary()} | {:error, :invalid_pem_certificate}
  defp pem_to_der(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] -> {:ok, der}
      _ -> {:error, :invalid_pem_certificate}
    end
  end

  defp pem_to_der(_), do: {:error, :invalid_pem_certificate}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Pulls the value of the ID attribute from a generated AuthnRequest element.
  @spec extract_id(term()) :: String.t()
  defp extract_id(xml_element) do
    xml_element
    |> xmlElement(:attributes)
    |> Enum.find_value(fn attr ->
      case xmlAttribute(attr, :name) do
        :ID -> xmlAttribute(attr, :value)
        _ -> nil
      end
    end)
    |> to_string()
  end

  # Accepts both string- and atom-keyed config maps.
  @spec fetch_key(map(), atom(), term()) :: term()
  defp fetch_key(config, key, default \\ nil) do
    Map.get(config, key) || Map.get(config, to_string(key)) || default
  end
end
