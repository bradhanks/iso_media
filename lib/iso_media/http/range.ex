defmodule ISOMedia.HTTP.Range do
  @moduledoc """
  RFC 7233 `Range` header parsing for byte ranges.

  `parse/3` returns `{:ok, ranges}` (normalized, inclusive, absolute, sorted, coalesced),
  `:unsatisfiable` (→ HTTP 416), or `:ignore` (→ serve the full 200 response). It never
  raises on untrusted input: a malformed header degrades to `:ignore`.
  """

  @default_max_ranges 100

  @type range :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Parse a `Range` header against the resource's `total` size.

  Options:
    * `:coalesce` — merge overlapping/adjacent ranges (default `true`)
    * `:max_ranges` — cap on coalesced range count; over the cap ⇒ `:ignore` (default `100`)
  """
  @spec parse(binary(), non_neg_integer(), keyword()) ::
          {:ok, [range()]} | :unsatisfiable | :ignore
  def parse(header, total, opts \\ [])

  def parse(header, total, opts)
      when is_binary(header) and is_integer(total) and total >= 0 do
    coalesce? = Keyword.get(opts, :coalesce, true)
    max = Keyword.get(opts, :max_ranges, @default_max_ranges)

    case unit_specs(header) do
      :ignore ->
        :ignore

      {:ok, specs} ->
        case classify(specs, total) do
          :ignore -> :ignore
          {[], true} -> :unsatisfiable
          {[], false} -> :ignore
          {sat, _any_unsat?} -> finalize(sat, coalesce?, max)
        end
    end
  end

  def parse(_header, total, _opts) when is_integer(total) and total >= 0, do: :ignore

  defp finalize(sat, coalesce?, max) do
    sorted = Enum.sort(sat)
    ranges = if coalesce?, do: coalesce(sorted), else: sorted
    # Over the cap we intentionally degrade to a full 200 response (:ignore), not 416.
    if length(ranges) > max, do: :ignore, else: {:ok, ranges}
  end

  # "bytes=a-b,c-d" -> {:ok, ["a-b", "c-d"]} | :ignore
  defp unit_specs(header) do
    case String.split(String.trim(header), "=", parts: 2) do
      [unit, rest] ->
        if String.downcase(unit) == "bytes" do
          specs =
            rest |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

          if specs == [], do: :ignore, else: {:ok, specs}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  # Returns {satisfiable_ranges, any_unsatisfiable?} or :ignore (any syntax error).
  defp classify(specs, total) do
    Enum.reduce_while(specs, {[], false}, fn spec, {sat, unsat?} ->
      case spec(spec, total) do
        {:ok, fl} -> {:cont, {[fl | sat], unsat?}}
        :unsat -> {:cont, {sat, true}}
        :error -> {:halt, :ignore}
      end
    end)
  end

  defp spec(_spec, 0), do: :unsat

  defp spec(spec, total) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] -> suffix_spec(suffix, total)
      [first, ""] -> open_spec(first, total)
      [first, last] -> closed_spec(first, last, total)
      _ -> :error
    end
  end

  defp suffix_spec(suffix, total) do
    case int(suffix) do
      {:ok, 0} -> :unsat
      {:ok, n} -> {:ok, {max(0, total - n), total - 1}}
      :error -> :error
    end
  end

  defp open_spec(first, total) do
    case int(first) do
      {:ok, f} when f >= total -> :unsat
      {:ok, f} -> {:ok, {f, total - 1}}
      :error -> :error
    end
  end

  defp closed_spec(first, last, total) do
    case {int(first), int(last)} do
      {{:ok, f}, {:ok, l}} when f <= l and f >= total -> :unsat
      {{:ok, f}, {:ok, l}} when f <= l -> {:ok, {f, min(l, total - 1)}}
      _ -> :error
    end
  end

  # RFC 7233 byte-pos / suffix-length are 1*DIGIT — ASCII digits only.
  # (Integer.parse/1 would accept a leading "+", so gate on digits first.)
  defp int(s) do
    if s != "" and String.match?(s, ~r/\A[0-9]+\z/) do
      {:ok, String.to_integer(s)}
    else
      :error
    end
  end

  # Merge overlapping/adjacent ranges in an already-sorted list.
  defp coalesce([]), do: []

  defp coalesce([first | rest]) do
    rest
    |> Enum.reduce([first], fn {f, l}, [{pf, pl} | acc] ->
      if f <= pl + 1, do: [{pf, max(pl, l)} | acc], else: [{f, l}, {pf, pl} | acc]
    end)
    |> Enum.reverse()
  end
end
