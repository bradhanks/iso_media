defmodule PerfectPaper.Accounts.OAuth.Assent do
  @moduledoc """
  Default OAuth adapter, backed by Assent. The only module that references
  Assent strategies or provider claim shapes. Reads per-provider credentials
  from `config :perfect_paper, :oauth_providers`.
  """
  @behaviour PerfectPaper.Accounts.OAuth

  @strategies %{
    "google" => Assent.Strategy.Google,
    "github" => Assent.Strategy.Github
  }

  @impl true
  @spec authorize_url(PerfectPaper.Accounts.OAuth.provider()) ::
          {:ok, %{url: String.t(), session_params: PerfectPaper.Accounts.OAuth.session_params()}}
          | {:error, term()}
  def authorize_url(provider) do
    with {:ok, {strategy, config}} <- provider_config(provider) do
      strategy.authorize_url(config)
    end
  end

  @impl true
  @spec callback(
          PerfectPaper.Accounts.OAuth.provider(),
          map(),
          PerfectPaper.Accounts.OAuth.session_params()
        ) :: {:ok, PerfectPaper.Accounts.OAuth.identity()} | {:error, term()}
  def callback(provider, params, session_params) do
    with {:ok, {strategy, config}} <- provider_config(provider) do
      config = Keyword.put(config, :session_params, session_params)

      case strategy.callback(config, params) do
        {:ok, %{user: user}} -> {:ok, normalize(provider, user)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Normalises provider claims into the `OAuth.identity` map. We trust the
  provider's own `email_verified` claim — Assent populates it for Google (OIDC)
  and for GitHub (whose strategy reads the primary email's `verified` flag from
  `/user/emails`). An email counts as verified only when it is present AND the
  provider reports it verified; this is what gates auto-linking.
  """
  @spec normalize(String.t(), map()) :: PerfectPaper.Accounts.OAuth.identity()
  def normalize(provider, claims) do
    email = claims["email"]

    %{
      provider: provider,
      uid: to_string(claims["sub"]),
      email: email,
      email_verified: not is_nil(email) and claims["email_verified"] == true,
      name: claims["name"]
    }
  end

  defp provider_config(provider) do
    providers = Application.get_env(:perfect_paper, :oauth_providers, %{})

    case {Map.get(providers, provider), Map.get(@strategies, provider)} do
      {opts, strategy} when is_list(opts) and not is_nil(strategy) ->
        config =
          opts
          |> Keyword.put_new(:http_adapter, Assent.HTTPAdapter.Req)
          |> Keyword.put(:redirect_uri, redirect_uri(provider))

        {:ok, {strategy, config}}

      _ ->
        {:error, :unconfigured_provider}
    end
  end

  defp redirect_uri(provider) do
    PerfectPaperWeb.Endpoint.url() <> "/auth/#{provider}/callback"
  end
end
