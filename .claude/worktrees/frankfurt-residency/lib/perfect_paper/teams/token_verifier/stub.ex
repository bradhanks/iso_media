defmodule PerfectPaper.Teams.TokenVerifier.Stub do
  @moduledoc """
  Test verifier. Default behaviour is ACCEPT so happy-path tests need no setup.
  Force rejection with `Process.put(:teams_verify, {:error, :reason})`.
  """
  @behaviour PerfectPaper.Teams.TokenVerifier

  @impl true
  def verify(_auth_header, _service_url) do
    Process.get(:teams_verify, {:ok, %{"aud" => "stub-app-id"}})
  end
end
