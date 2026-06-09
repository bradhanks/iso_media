defmodule PerfectPaper.Teams.TokenVerifier.AlwaysReject do
  @moduledoc "Test-only verifier that rejects every token (exercises the 401 controller path)."
  @behaviour PerfectPaper.Teams.TokenVerifier

  @impl true
  def verify(_auth_header, _service_url), do: {:error, :rejected}
end
