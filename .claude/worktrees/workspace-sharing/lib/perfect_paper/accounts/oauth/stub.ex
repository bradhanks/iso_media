defmodule PerfectPaper.Accounts.OAuth.Stub do
  @moduledoc """
  Test adapter. Tests seed the next `callback/3` result with `put_identity/1`
  (or `put_error/1`); `authorize_url/1` returns a fixed fake URL.
  """
  @behaviour PerfectPaper.Accounts.OAuth

  @key {__MODULE__, :identity}

  @doc "Seed the identity the next `callback/3` returns."
  def put_identity(identity), do: Process.put(@key, {:ok, identity})

  @doc "Seed an error the next `callback/3` returns."
  def put_error(reason), do: Process.put(@key, {:error, reason})

  @impl true
  def authorize_url(provider) do
    {:ok, %{url: "https://example.test/auth/#{provider}", session_params: %{state: "stub-state"}}}
  end

  @impl true
  def callback(_provider, _params, _session_params) do
    Process.get(@key, {:error, :no_stub_identity})
  end
end
