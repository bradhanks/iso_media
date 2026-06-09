defmodule PerfectPaper.Documents.Importer.Panpipe do
  @moduledoc """
  Default importer adapter. Delegates to the panpipe `Canonical` library, which
  owns the Pandoc→canonical transform. Returns the boundary contract
  `{:ok, %{doc: map(), meta: map()}}`; panpipe's `warnings` are dropped here.

  Per the `Importer` behaviour, no third-party shapes leak past this adapter:
  panpipe's `{:invalid, violations}` and Exile's `AbnormalExit` are normalized to
  our own deterministic failure vocabulary (`{:invalid_document, _}`,
  `:unconvertible_source`) that the conversion worker classifies.
  """
  @behaviour PerfectPaper.Documents.Importer

  @impl true
  def import(content, opts) do
    case Canonical.import_document(content, opts) do
      {:ok, %{doc: doc, meta: meta}} -> {:ok, %{doc: doc, meta: meta}}
      {:error, {:invalid, violations}} -> {:error, {:invalid_document, violations}}
      {:error, %Exile.Stream.AbnormalExit{}} -> {:error, :unconvertible_source}
      {:error, _} = error -> error
    end
  end
end
