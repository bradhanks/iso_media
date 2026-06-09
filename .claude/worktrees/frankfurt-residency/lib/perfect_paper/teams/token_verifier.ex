defmodule PerfectPaper.Teams.TokenVerifier do
  @moduledoc """
  Verifies the Bot Framework JWT on every inbound Teams Activity — the sole
  authentication for the public `/teams/messages` endpoint. Validates signature
  (against the cached Bot Framework JWKS), `iss == https://api.botframework.com`,
  `aud == <bot app id>`, and that the token's `serviceUrl` claim equals the
  activity's `serviceUrl` (replay defense). Config-selected adapter; stub default
  in test. The real adapter (JWKS fetch + JOSE verify) is `TODO(teams)`.
  """

  @type claims :: map()

  @callback verify(auth_header :: String.t() | nil, service_url :: String.t()) ::
              {:ok, claims()} | {:error, atom()}

  @doc "Returns the configured adapter module (default: Stub)."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(
      :perfect_paper,
      :teams_token_verifier,
      PerfectPaper.Teams.TokenVerifier.Stub
    )
  end

  @doc """
  Verifies the Bot Framework bearer token. Delegates to the configured adapter.

  Checks performed by a real adapter:
  1. JWT signature — validated against the cached Bot Framework JWKS.
  2. `iss` claim — must equal `https://api.botframework.com`.
  3. `aud` claim — must equal the bot's Azure App ID.
  4. `serviceUrl` claim — must equal the Activity's `serviceUrl` (replay defense).

  Returns `{:ok, claims}` on success or `{:error, reason}` on any failure.
  """
  @spec verify(String.t() | nil, String.t()) :: {:ok, claims()} | {:error, atom()}
  def verify(auth_header, service_url), do: adapter().verify(auth_header, service_url)
end
