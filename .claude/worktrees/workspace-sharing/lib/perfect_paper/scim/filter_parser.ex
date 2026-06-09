defmodule PerfectPaper.Scim.FilterParser do
  @moduledoc """
  A deliberately minimal SCIM filter parser for the only filters Entra sends:
  `userName eq "…"`, `externalId eq "…"`, `displayName eq "…"`. Attribute name
  is case-insensitive; the value is an exact match. Anything else (other
  operators, compound `and`/`or`, empty, malformed) returns `:no_match` — it
  NEVER raises and NEVER produces an error, so an unrecognized filter degrades
  to "no resource matches" (Entra Test-Connection safety).
  """

  @type result :: {:eq, :user_name | :external_id | :display_name, String.t()} | :no_match

  @attrs %{"username" => :user_name, "externalid" => :external_id, "displayname" => :display_name}

  @doc """
  Parses a SCIM filter string into a single `eq` clause, or `:no_match`.

  Entra may fully-qualify the attribute with its schema URN
  (`urn:ietf:params:scim:schemas:core:2.0:User:userName eq "…"`); the regex
  accepts URN characters and we take the segment after the last colon as the
  attribute name.
  """
  @spec parse(String.t() | nil) :: result()
  def parse(filter) when is_binary(filter) do
    case Regex.run(~r/^\s*([\w.:-]+)\s+eq\s+"([^"]*)"\s*$/i, filter) do
      [_, attr, value] ->
        base_attr = attr |> String.split(":") |> List.last() |> String.downcase()

        case Map.fetch(@attrs, base_attr) do
          {:ok, key} -> {:eq, key, value}
          :error -> :no_match
        end

      _ ->
        :no_match
    end
  end

  def parse(_), do: :no_match
end
