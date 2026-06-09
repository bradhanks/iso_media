defmodule PerfectPaper.Documents.Importer do
  @moduledoc """
  Anti-corruption boundary for document ingestion. An importer turns a raw
  uploaded binary into our canonical SSoT — `%{doc: canonical_map, meta: map}`.
  No third-party AST shapes (Pandoc/Panpipe) leak past an implementation.
  """

  @doc "Imports raw `content` into a canonical doc + extracted metadata."
  @callback import(content :: binary(), opts :: keyword()) ::
              {:ok, %{doc: map(), meta: map()}} | {:error, term()}
end
