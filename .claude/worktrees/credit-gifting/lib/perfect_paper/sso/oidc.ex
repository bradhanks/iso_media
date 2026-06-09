defmodule PerfectPaper.SSO.OIDC do
  @moduledoc """
  OIDC adapter for per-org, tenant-scoped Microsoft Entra (Azure AD) SSO.

  Implements `PerfectPaper.SSO.Provider` using `Assent.Strategy.OIDC`
  (generic OIDC strategy) with tenant-scoped Entra discovery.

  This is the only module that references Assent or Entra-specific claim
  shapes. Everything above this layer receives a normalized `identity` map.

  ## Config map keys expected by `authorize_url/2` and `callback/3`

    - `:tenant_id`     - the Azure/Entra tenant UUID or name (required)
    - `:client_id`     - the Entra app registration client ID (required)
    - `:client_secret` - the Entra app registration client secret (required)
    - `:redirect_uri`  - the absolute callback URL (required)
    - `:org_id`        - PerfectPaper organization ID, used to scope the
                         `provider` key in the returned identity so identities
                         from different orgs' Entra tenants never collide on
                         `(provider, uid)` even when two orgs share a tenant

  All keys are strings or atoms — the adapter accepts either form.
  """

  @behaviour PerfectPaper.SSO.Provider

  alias Assent.Strategy.OIDC, as: AssentOIDC

  # Scopes requested from Entra.
  @default_scope "openid email profile"

  # ---------------------------------------------------------------------------
  # Pure helpers — unit-testable without a live IdP call
  # ---------------------------------------------------------------------------

  @doc """
  Returns the tenant-scoped Entra v2.0 issuer / authority base URL.

  This is the value passed as `:base_url` to Assent OIDC, which appends
  `/.well-known/openid-configuration` to discover token/authorization
  endpoints.

  ## Examples

      iex> PerfectPaper.SSO.OIDC.authority_url("my-tenant-id")
      "https://login.microsoftonline.com/my-tenant-id/v2.0"
  """
  @spec authority_url(String.t()) :: String.t()
  def authority_url(tenant_id),
    do: "https://login.microsoftonline.com/#{tenant_id}/v2.0"

  @doc """
  Maps Entra OIDC claims to the normalized `SSO.Provider.identity` map.

  The `provider` key is scoped to the org so identities from different orgs
  (even those sharing the same Entra tenant) never collide on `(provider, uid)`.

  `email_verified` is `true` when the claim is the boolean `true` **or** the
  string `"true"`; anything else (including absent) is `false`.

  ## Examples

      iex> claims = %{"sub" => "u1", "email" => "a@corp.com",
      ...>             "email_verified" => true, "name" => "Alice"}
      iex> PerfectPaper.SSO.OIDC.to_identity(claims, "org_abc")
      %{
        provider: "oidc:org_abc",
        uid: "u1",
        email: "a@corp.com",
        email_verified: true,
        name: "Alice"
      }
  """
  @spec to_identity(map(), String.t()) :: PerfectPaper.SSO.Provider.identity()
  def to_identity(claims, org_id) do
    %{
      provider: "oidc:#{org_id}",
      uid: to_string(claims["sub"]),
      email: claims["email"],
      email_verified: claims["email_verified"] in [true, "true"],
      name: claims["name"]
    }
  end

  # ---------------------------------------------------------------------------
  # Provider behaviour
  # ---------------------------------------------------------------------------

  @doc """
  Generates an authorization URL for the Entra tenant.

  Delegates to `Assent.Strategy.OIDC.authorize_url/1` after building a
  tenant-scoped Assent config. Returns `{:ok, %{url: url, session_params: map}}`.

  No session state from `session_params` needs to be merged in for the
  authorize step — Assent generates its own `:state` internally and returns
  it in `:session_params`.
  """
  @impl true
  @spec authorize_url(map(), map()) ::
          {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}
  def authorize_url(config, _session_params) do
    config
    |> build_assent_config()
    |> AssentOIDC.authorize_url()
  end

  @doc """
  Exchanges the authorization callback params for a normalized identity.

  Merges `session_params` into the Assent config (where Assent expects it
  to validate state/nonce), calls `Assent.Strategy.OIDC.callback/2`, and
  on success maps the raw claims to the normalized `identity` map via
  `to_identity/2`.
  """
  @impl true
  @spec callback(map(), map(), map()) ::
          {:ok, PerfectPaper.SSO.Provider.identity()} | {:error, term()}
  def callback(config, params, session_params) do
    assent_config =
      config
      |> build_assent_config()
      |> Keyword.put(:session_params, session_params)

    org_id = fetch_key(config, :org_id, "unknown")

    case AssentOIDC.callback(assent_config, params) do
      {:ok, %{user: claims}} -> {:ok, to_identity(claims, org_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — Assent config construction
  # ---------------------------------------------------------------------------

  # Builds the Keyword list that Assent.Strategy.OIDC expects.
  # All Assent-specific keys are confined here.
  @spec build_assent_config(map()) :: Keyword.t()
  defp build_assent_config(config) do
    tenant_id = fetch_key(config, :tenant_id)

    base =
      [
        client_id: fetch_key(config, :client_id),
        client_secret: fetch_key(config, :client_secret),
        redirect_uri: fetch_key(config, :redirect_uri),
        base_url: authority_url(tenant_id),
        authorization_params: [scope: @default_scope],
        http_adapter: Assent.HTTPAdapter.Req
      ]

    # If the caller injects a pre-fetched openid_configuration map (useful in
    # tests to avoid a live HTTP discovery call), honour it.
    case Map.get(config, :openid_configuration) || config[:openid_configuration] do
      nil -> base
      oc -> Keyword.put(base, :openid_configuration, oc)
    end
  end

  # Accepts both string and atom keys in the incoming config map.
  defp fetch_key(config, key, default \\ nil) do
    Map.get(config, key) || Map.get(config, to_string(key)) || default
  end
end
