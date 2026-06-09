defmodule PerfectPaper.SSO do
  @moduledoc """
  Enterprise Single Sign-On configuration for organizations.

  Manages per-org SSO credential config (OIDC / SAML), domain ownership
  verification, and the enable/disable gate. Also provides login-routing via
  `config_for_email/1` — the only function here that is NOT access-controlled.

  All management operations are org-admin gated: only the org owner or a member
  with the `:admin` role may call them. Callers pass an `Accounts.Scope`; the
  scope must carry a `user.id` to satisfy the gate.

  This is the public API and the only `Repo` / IO boundary for the SSO context.
  """

  alias Ecto.Changeset
  alias PerfectPaper.{Repo, Accounts, Organizations}
  alias PerfectPaper.Accounts.{Scope, User}
  alias PerfectPaper.Organizations.Organization
  alias PerfectPaper.SSO.{SsoConfig, Provider}

  # ── Config CRUD ────────────────────────────────────────────────────────────

  @doc """
  Creates or updates the SSO config for `org`.

  Credentials (protocol, email_domain, OIDC/SAML fields) are validated via
  `SsoConfig.changeset/2`. `domain_verified` and `enabled` are never touched
  here — use `verify_domain/2` and `enable_sso/3` for those.

  Returns `{:ok, config}` | `{:error, :unauthorized}` | `{:error, changeset}`.
  """
  @spec configure_sso(Organization.t(), Scope.t(), map()) ::
          {:ok, SsoConfig.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def configure_sso(%Organization{} = org, %Scope{user: %{id: uid}}, attrs) do
    if Organizations.admin?(org, uid) do
      attrs_with_org = Map.put(attrs, :organization_id, org.id)

      case Repo.get_by(SsoConfig, organization_id: org.id) do
        nil ->
          %SsoConfig{}
          |> SsoConfig.changeset(attrs_with_org)
          |> Repo.insert()

        existing ->
          existing
          |> SsoConfig.changeset(attrs_with_org)
          |> maybe_revoke_if_security_fields_changed(existing)
          |> Repo.update()
      end
    else
      {:error, :unauthorized}
    end
  end

  # The credential fields the SSO changeset accepts. Raw web input arrives with
  # string keys; we coerce to atoms over this fixed whitelist only — never
  # String.to_atom/1 on arbitrary input.
  @config_keys ~w(
    protocol email_domain
    oidc_tenant_id oidc_client_id oidc_client_secret
    saml_idp_entity_id saml_idp_sso_url saml_idp_cert saml_sp_entity_id
  )

  @doc """
  Normalizes raw string-keyed SSO config params to the atom-keyed whitelist the
  changeset accepts. Web-input adaptation; unknown keys are dropped. Keys are
  mapped via `String.to_existing_atom/1` over a fixed list, so untrusted input
  cannot create new atoms.
  """
  @spec config_attrs(map()) :: map()
  def config_attrs(params) when is_map(params) do
    for key <- @config_keys, Map.has_key?(params, key), into: %{} do
      {String.to_existing_atom(key), params[key]}
    end
  end

  @doc """
  Returns the SSO config for `org`, or `nil` if none exists.

  Not access-gated — used internally for verification and routing lookups.
  Callers that present this to end-users should apply their own auth check.
  """
  @spec get_config(Organization.t()) :: SsoConfig.t() | nil
  def get_config(%Organization{id: org_id}) do
    Repo.get_by(SsoConfig, organization_id: org_id)
  end

  @doc """
  Returns the enabled+verified SSO config for `org_id`, or `nil` if none exists
  or the config is not yet verified and enabled.

  Not access-gated — used by the SSO callback route to look up the config for
  a given org before the user session exists.
  """
  @spec get_config_by_org_id(binary()) :: SsoConfig.t() | nil
  def get_config_by_org_id(org_id) when is_binary(org_id) do
    # Guard a malformed (non-UUID) org_id — the public /sso/:org_id endpoints are
    # unauthenticated, so a bad id must yield nil (→ graceful redirect), not a 500.
    if PerfectPaper.UUID.valid?(org_id) do
      case Repo.get_by(SsoConfig, organization_id: org_id) do
        %SsoConfig{enabled: true, domain_verified: true} = config -> config
        _ -> nil
      end
    else
      nil
    end
  end

  # ── Domain verification ────────────────────────────────────────────────────

  @doc """
  Marks the org's SSO domain as verified.

  This pass trusts an admin-triggered verification action without DNS proof.

  # TODO(sso): real DNS-TXT domain verification

  Returns `{:ok, config}` | `{:error, :unauthorized}` | `{:error, :not_found}`.
  """
  @spec verify_domain(Organization.t(), Scope.t()) ::
          {:ok, SsoConfig.t()} | {:error, :unauthorized | :not_found}
  def verify_domain(%Organization{} = org, %Scope{user: %{id: uid}}) do
    if Organizations.admin?(org, uid) do
      case get_config(org) do
        nil ->
          {:error, :not_found}

        config ->
          config
          |> Changeset.change(%{domain_verified: true})
          |> Repo.update()
      end
    else
      {:error, :unauthorized}
    end
  end

  # ── Enable / disable ───────────────────────────────────────────────────────

  @doc """
  Enables or disables SSO for the org.

  When `enabled?` is `true`, the config MUST already have `domain_verified: true`
  — otherwise returns `{:error, :domain_not_verified}`. This is the security gate
  that prevents routing login traffic to an unverified IdP.

  Returns `{:ok, config}` | `{:error, :unauthorized | :not_found | :domain_not_verified}`.
  """
  @spec enable_sso(Organization.t(), Scope.t(), boolean()) ::
          {:ok, SsoConfig.t()}
          | {:error, :unauthorized | :not_found | :domain_not_verified}
  def enable_sso(%Organization{} = org, %Scope{user: %{id: uid}}, enabled?)
      when is_boolean(enabled?) do
    if Organizations.admin?(org, uid) do
      case get_config(org) do
        nil ->
          {:error, :not_found}

        %SsoConfig{domain_verified: false} when enabled? ->
          {:error, :domain_not_verified}

        config ->
          config
          |> Changeset.change(%{enabled: enabled?})
          |> Repo.update()
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Disables SSO for the org. Convenience wrapper around `enable_sso/3`.

  Returns `{:ok, config}` | `{:error, :unauthorized | :not_found}`.
  """
  @spec disable_sso(Organization.t(), Scope.t()) ::
          {:ok, SsoConfig.t()} | {:error, :unauthorized | :not_found}
  def disable_sso(%Organization{} = org, %Scope{} = scope) do
    enable_sso(org, scope, false)
  end

  # ── Sign-in flow ──────────────────────────────────────────────────────────

  @doc """
  Builds the IdP authorize URL for the given SSO config.

  Returns `{:ok, %{url: url, session_params: map()}}` on success or
  `{:error, term()}` when the adapter fails. The session_params must be
  stored in the browser session and passed to `sign_in/3` to prevent CSRF.
  """
  @spec authorize_url(SsoConfig.t()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  def authorize_url(%SsoConfig{} = config) do
    Provider.for_protocol(config.protocol).authorize_url(provider_config(config), %{})
  end

  @doc """
  Completes an enterprise SSO callback and signs the user in with JIT provisioning.

  Steps:
  1. Calls the adapter `callback/3` to exchange the IdP params for a normalized
     identity (provider, uid, email, email_verified, name).
  2. Verifies the identity email domain matches `config.email_domain` (both sides
     sanitized so mixed-case Entra addresses like `Alice@Acme.COM` compare
     correctly).
  3. Resolves the identity to a user via `Accounts.resolve_sso_identity/2` with
     `trusted_domain: true` — this enables Rule 1 (guest promotion) and Rule 2
     (squatter neutralization) only on enterprise-verified domains.
  4. Ensures JIT org membership (idempotent).

  Returns `{:ok, user}` or `{:error, reason}` where reason is one of:
  `:domain_mismatch`, `:email_required`, `:email_taken`, or an adapter error.
  """
  @spec sign_in(SsoConfig.t(), map(), map()) ::
          {:ok, User.t()} | {:error, :domain_mismatch | :email_required | term()}
  def sign_in(%SsoConfig{} = config, params, session_params) do
    with {:ok, identity} <-
           Provider.for_protocol(config.protocol).callback(
             provider_config(config),
             params,
             session_params
           ),
         :ok <- check_email_domain(identity, config),
         {:ok, user} <- Accounts.resolve_sso_identity(identity, trusted_domain: true),
         # Fail closed for a deprovisioned account: never mint a session or
         # silently re-add org membership for a deactivated user.
         :ok <- ensure_not_deactivated(user) do
      ensure_member(config.organization_id, user)
      {:ok, user}
    end
  end

  defp ensure_not_deactivated(%{deactivated_at: nil}), do: :ok
  defp ensure_not_deactivated(_), do: {:error, :account_deactivated}

  # ── Login routing ──────────────────────────────────────────────────────────

  @doc """
  Looks up a ready-to-use SSO config by the domain part of an email address.

  Extracts the domain (lowercased), queries for a matching `SsoConfig`, and
  returns it only when BOTH `enabled` AND `domain_verified` are `true`. Returns
  `nil` in all other cases: no config, unverified domain, or disabled SSO.

  This function is NOT access-gated — it is called during login routing before
  any user session exists.
  """
  @spec config_for_email(String.t()) :: SsoConfig.t() | nil
  def config_for_email(email) when is_binary(email) do
    domain =
      email
      |> String.split("@")
      |> List.last()
      |> SsoConfig.sanitize_domain()

    case Repo.get_by(SsoConfig, email_domain: domain) do
      %SsoConfig{enabled: true, domain_verified: true} = config -> config
      _ -> nil
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  # Builds the adapter config map from an SsoConfig struct. The Stub adapter
  # ignores the config; real adapters use tenant/client/secret/redirect_uri.
  @spec provider_config(SsoConfig.t()) :: map()
  defp provider_config(%SsoConfig{} = cfg) do
    %{
      organization_id: cfg.organization_id,
      protocol: cfg.protocol,
      oidc_tenant_id: cfg.oidc_tenant_id,
      oidc_client_id: cfg.oidc_client_id,
      oidc_client_secret: cfg.oidc_client_secret,
      saml_idp_entity_id: cfg.saml_idp_entity_id,
      saml_idp_sso_url: cfg.saml_idp_sso_url,
      saml_idp_cert: cfg.saml_idp_cert,
      saml_sp_entity_id: cfg.saml_sp_entity_id
    }
  end

  # Verifies that the identity email's domain matches the config's stored domain.
  # Both sides are sanitized (lowercased, leading @ stripped, trailing / stripped)
  # so mixed-case IdP addresses like `Alice@ACME.COM` match a stored `acme.com`.
  @spec check_email_domain(map(), SsoConfig.t()) ::
          :ok | {:error, :email_required | :domain_mismatch}
  defp check_email_domain(%{email: nil}, _config), do: {:error, :email_required}

  defp check_email_domain(%{email: email}, %SsoConfig{email_domain: stored_domain}) do
    identity_domain =
      email
      |> String.split("@")
      |> List.last()
      |> SsoConfig.sanitize_domain()

    if identity_domain == SsoConfig.sanitize_domain(stored_domain) do
      :ok
    else
      {:error, :domain_mismatch}
    end
  end

  # Adds the user to the org if they are not already a member. The [org, user]
  # unique constraint violation is treated as success — idempotent by design.
  @spec ensure_member(binary(), struct()) :: :ok
  defp ensure_member(organization_id, user) do
    org = Repo.get!(Organization, organization_id)

    case Organizations.add_member(org, user) do
      {:ok, _} -> :ok
      # Unique constraint: user is already a member — that is fine.
      {:error, %Ecto.Changeset{}} -> :ok
    end
  end

  # Security-sensitive fields whose change on a verified+enabled config must
  # force-reset domain_verified and enabled to prevent domain/IdP hijacking.
  @security_fields [
    :email_domain,
    :oidc_tenant_id,
    :oidc_client_id,
    :oidc_client_secret,
    :saml_idp_entity_id,
    :saml_idp_sso_url,
    :saml_idp_cert,
    :saml_sp_entity_id
  ]

  # If the existing config is verified+enabled AND any security-sensitive field
  # is changing, force domain_verified=false and enabled=false so the admin must
  # re-verify and re-enable after the credential/domain change.
  defp maybe_revoke_if_security_fields_changed(changeset, %SsoConfig{
         domain_verified: true,
         enabled: true
       }) do
    security_changed? =
      Enum.any?(@security_fields, &Changeset.changed?(changeset, &1))

    if security_changed? do
      changeset
      |> Changeset.put_change(:domain_verified, false)
      |> Changeset.put_change(:enabled, false)
    else
      changeset
    end
  end

  defp maybe_revoke_if_security_fields_changed(changeset, _existing), do: changeset
end
