defmodule PerfectPaper.UUID do
  @moduledoc """
  Tiny shared leaf: is a value a well-formed UUID?

  Guard external (request-supplied) ids with this before a `binary_id` query so a
  malformed id yields a clean not-found / nil instead of raising
  `Ecto.Query.CastError` — which Phoenix turns into a 500. Context lookups that
  take an id straight from a URL/path/header use it.
  """
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  def valid?(_), do: false
end
