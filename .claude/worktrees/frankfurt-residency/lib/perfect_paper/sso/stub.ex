defmodule PerfectPaper.SSO.Stub do
  @moduledoc "Test SSO adapter — no real IdP. Returns a configurable identity from the process dictionary."
  @behaviour PerfectPaper.SSO.Provider

  @default_identity %{
    provider: "stub",
    uid: "stub-uid",
    email: "user@acme.test",
    email_verified: true,
    name: "Test User"
  }

  @impl true
  def authorize_url(_config, session_params),
    do:
      {:ok,
       %{
         url: "https://idp.test/authorize?state=test",
         session_params: Map.put_new(session_params, :state, "test")
       }}

  @impl true
  def callback(_config, _params, _session_params),
    do: {:ok, Process.get(:sso_stub_identity, @default_identity)}
end
