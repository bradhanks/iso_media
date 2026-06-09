defmodule PerfectPaper.Accounts.OAuth do
  @moduledoc """
  Anti-corruption boundary for social sign-in. The adapter is the only module
  that talks to a provider; it returns a normalised, atom-keyed `identity` map
  so the `Accounts` context never sees provider/Assent specifics.

  Select the adapter with `config :perfect_paper, :oauth_adapter, Module`.
  """

  @type provider :: String.t()
  @type session_params :: map()
  @type identity :: %{
          provider: String.t(),
          uid: String.t(),
          email: String.t() | nil,
          email_verified: boolean(),
          name: String.t() | nil
        }

  @callback authorize_url(provider) ::
              {:ok, %{url: String.t(), session_params: session_params}}
              | {:error, term()}

  @callback callback(provider, params :: map(), session_params) ::
              {:ok, identity} | {:error, term()}

  @doc "The configured adapter module."
  @spec adapter() :: module()
  def adapter, do: Application.fetch_env!(:perfect_paper, :oauth_adapter)
end
