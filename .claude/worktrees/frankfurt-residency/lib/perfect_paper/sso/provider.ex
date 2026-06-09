defmodule PerfectPaper.SSO.Provider do
  @moduledoc """
  Anti-corruption boundary for per-org enterprise SSO. An adapter (OIDC/SAML) is
  the only module that touches a protocol library; it returns a normalized,
  atom-keyed `identity` map so the `SSO` context never sees protocol specifics.
  Select adapters via `config :perfect_paper, :sso_adapters, oidc: M, saml: M`.
  """

  @type identity :: %{
          provider: String.t(),
          uid: String.t(),
          email: String.t() | nil,
          email_verified: boolean(),
          name: String.t() | nil
        }

  @callback authorize_url(config :: map(), session_params :: map()) ::
              {:ok, %{url: String.t(), session_params: map()}} | {:error, term()}

  @callback callback(config :: map(), params :: map(), session_params :: map()) ::
              {:ok, identity} | {:error, term()}

  @doc "The configured adapter module for a protocol (:oidc | :saml)."
  @spec for_protocol(:oidc | :saml) :: module()
  def for_protocol(protocol) do
    adapters = Application.get_env(:perfect_paper, :sso_adapters, [])
    adapters[protocol] || default_adapter(protocol)
  end

  defp default_adapter(:oidc), do: PerfectPaper.SSO.OIDC
  defp default_adapter(:saml), do: PerfectPaper.SSO.SAML
end
