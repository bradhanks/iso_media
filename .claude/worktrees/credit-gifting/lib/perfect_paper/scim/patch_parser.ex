defmodule PerfectPaper.Scim.PatchParser do
  @moduledoc """
  Normalizes a SCIM PatchOp body into a flat list of canonical operations,
  tolerating Entra's variations: `active` may be targeted via `"path"` or nested
  under `"value"`, and booleans may be literal (`false`) or stringified
  (`"false"`). Unrecognized ops are ignored; a structurally invalid body returns
  `{:error, :invalid_syntax}` (the controller renders 400 `invalidSyntax`).
  """

  @type op ::
          {:set_active, boolean()}
          | {:set_display_name, String.t()}
          | {:add_members, [String.t()]}
          | {:remove_members, [String.t()]}
          | {:replace_members, [String.t()]}

  @doc "Parses a SCIM PatchOp map into canonical ops, or `{:error, :invalid_syntax}`."
  @spec parse(map()) :: {:ok, [op()]} | {:error, :invalid_syntax}
  def parse(%{"Operations" => ops}) when is_list(ops) do
    # SCIM `op` is case-insensitive (RFC 7644); some proxies upcase it. Normalize
    # to lowercase once so the clauses below stay simple.
    normalized = Enum.map(ops, &downcase_op/1)
    {:ok, Enum.flat_map(normalized, &normalize/1)}
  end

  def parse(_), do: {:error, :invalid_syntax}

  defp downcase_op(%{"op" => op} = o) when is_binary(op), do: %{o | "op" => String.downcase(op)}
  defp downcase_op(o), do: o

  # Path-targeted op (active / displayName / members replace).
  defp normalize(%{"op" => "replace", "path" => path} = o) do
    case String.downcase(path) do
      "active" -> [{:set_active, truthy(o["value"])}]
      "displayname" -> [{:set_display_name, o["value"]}]
      "members" -> [{:replace_members, member_ids(o["value"])}]
      _ -> []
    end
  end

  # Value-targeted op (no path): inspect the value map.
  defp normalize(%{"op" => "replace", "value" => %{} = value}) do
    Enum.flat_map(value, fn
      {"active", v} -> [{:set_active, truthy(v)}]
      {"displayName", v} -> [{:set_display_name, v}]
      _ -> []
    end)
  end

  defp normalize(%{"op" => "add", "path" => "members", "value" => v}),
    do: [{:add_members, member_ids(v)}]

  defp normalize(%{"op" => "remove", "path" => "members", "value" => v}),
    do: [{:remove_members, member_ids(v)}]

  defp normalize(_), do: []

  defp truthy(true), do: true
  defp truthy(false), do: false
  defp truthy(v) when is_binary(v), do: String.downcase(v) == "true"
  defp truthy(_), do: false

  defp member_ids(list) when is_list(list), do: Enum.map(list, & &1["value"])
  defp member_ids(_), do: []
end
