defmodule PerfectPaper.Documents.Importer.ErrorStub do
  @moduledoc """
  Test importer that returns a configurable `{:error, reason}` so the conversion
  worker's failure-classification can be exercised without a real corrupt upload.
  Set the reason via `Application.put_env(:perfect_paper, :error_stub_reason, ...)`.
  """
  @behaviour PerfectPaper.Documents.Importer

  @impl true
  def import(_content, _opts) do
    {:error, Application.get_env(:perfect_paper, :error_stub_reason, :boom)}
  end
end
