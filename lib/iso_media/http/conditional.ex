defmodule ISOMedia.HTTP.Conditional do
  @moduledoc """
  RFC 7232 §6 conditional-request precedence. Pure; never raises on untrusted input.

  `evaluate/2` runs the short-circuiting ladder (If-Match → If-Unmodified-Since →
  If-None-Match → If-Modified-Since) returning `:proceed | :not_modified | :precondition_failed`.
  `if_range_satisfied?/2` decides whether a present `Range` is honored (strong validators only).
  """

  alias ISOMedia.HTTP.{Date, Request, Resource}

  @spec evaluate(Request.t(), Resource.t()) :: :proceed | :not_modified | :precondition_failed
  def evaluate(%Request{} = req, %Resource{} = res) do
    cond do
      req.if_match != nil ->
        if match_strong?(req.if_match, res.etag), do: step3(req, res), else: :precondition_failed

      req.if_unmodified_since != nil ->
        case modified_since(res.last_modified, req.if_unmodified_since) do
          true -> :precondition_failed
          _ -> step3(req, res)
        end

      true ->
        step3(req, res)
    end
  end

  defp step3(req, res) do
    cond do
      req.if_none_match != nil ->
        if match_weak?(req.if_none_match, res.etag) do
          if req.method in [:get, :head], do: :not_modified, else: :precondition_failed
        else
          :proceed
        end

      req.if_modified_since != nil and req.method in [:get, :head] ->
        case modified_since(res.last_modified, req.if_modified_since) do
          false -> :not_modified
          _ -> :proceed
        end

      true ->
        :proceed
    end
  end

  @spec if_range_satisfied?(Request.t(), Resource.t()) :: boolean()
  def if_range_satisfied?(%Request{if_range: nil}, _res), do: true

  def if_range_satisfied?(%Request{if_range: ir}, %Resource{} = res) do
    ir = String.trim(ir)

    cond do
      String.starts_with?(ir, "\"") -> equal_strong?(ir, res.etag)
      String.starts_with?(ir, "W/") -> false
      true -> date_unchanged?(ir, res.last_modified)
    end
  end

  defp date_unchanged?(_ir, nil), do: false

  defp date_unchanged?(ir, last_modified) do
    case Date.parse(ir) do
      {:ok, dt} -> secs(last_modified) <= secs(dt)
      :error -> false
    end
  end

  # true (modified), false (not modified), or :unknown (can't determine → caller proceeds).
  defp modified_since(nil, _date), do: :unknown

  defp modified_since(last_modified, date_str) do
    case Date.parse(date_str) do
      {:ok, dt} -> secs(last_modified) > secs(dt)
      :error -> :unknown
    end
  end

  defp secs(dt), do: :calendar.datetime_to_gregorian_seconds(dt)

  # --- entity-tag matching ---
  defp match_strong?(header, etag), do: match(header, etag, &equal_strong?/2)
  defp match_weak?(header, etag), do: match(header, etag, &equal_weak?/2)

  defp match(header, etag, eq) do
    case String.trim(header) do
      "*" -> true
      h -> h |> split_tags() |> Enum.any?(&eq.(&1, etag))
    end
  end

  defp split_tags(s), do: Regex.scan(~r/(?:W\/)?"[^"]*"/, s) |> Enum.map(&hd/1)

  defp equal_strong?(a, b), do: not weak?(a) and not weak?(b) and opaque(a) == opaque(b)
  defp equal_weak?(a, b), do: opaque(a) == opaque(b)
  defp weak?(t), do: String.starts_with?(String.trim(t), "W/")
  defp opaque(t), do: t |> String.trim() |> String.replace_prefix("W/", "")
end
