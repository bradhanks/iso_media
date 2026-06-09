defmodule PerfectPaper.Documents.Storage do
  @moduledoc """
  Behaviour for blob storage adapters.

  The context selects the adapter at runtime via
  `Application.get_env(:perfect_paper, :storage_provider)`.
  No vendor-specific details leak past the adapter.
  """

  @doc "Stores binary content and returns the generated storage key."
  @callback store(binary(), keyword()) ::
              {:ok, %{storage_key: String.t()}} | {:error, term()}

  @doc "Reads the content previously stored under the given key."
  @callback read(String.t()) :: {:ok, binary()} | {:error, term()}
end
