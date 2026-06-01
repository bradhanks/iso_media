defmodule ISOMedia.Offsets do
  @moduledoc """
  Recomputes `stco`/`co64` chunk-offset tables after boxes have moved, and the
  `faststart/1` rearrangement built on top of it.

  Assumes `mdat` payloads are byte-identical to what was parsed (this is box
  relocation, not sample editing). Each `mdat` carries its current basis position
  via `source_offset`/`source_size`, so a chunk offset is remapped by the uniform
  byte delta of the `mdat` it points into. After remapping, each `mdat`'s
  `source_offset` is updated to its new position, which makes the operation
  idempotent and lets repeated edit→fix cycles compose.
  """

  alias ISOMedia.Layout
  alias ISOMedia.Boxes.ChunkOffset

  @uint32_max 0xFFFFFFFF
  @max_iterations 16

  @doc """
  Return `boxes` with every `stco`/`co64` table corrected for the current
  arrangement. Promotes `stco`→`co64` (latched, never demoted) when an offset
  reaches the `:co64_threshold` (default `#{@uint32_max}`), iterating layout to a
  fixpoint. Raises if an `mdat` was synthesized or resized, or if a chunk offset
  maps into no `mdat`.

  Options:
    * `:co64_threshold` — promote a table to `co64` when any offset exceeds this
      value. Defaults to 2^32 − 1; lower it only in tests to exercise promotion
      without a multi-gigabyte file.
  """
  def fix_chunk_offsets(boxes, opts \\ []) when is_list(boxes) do
    threshold = Keyword.get(opts, :co64_threshold, @uint32_max)
    mdats = Enum.filter(boxes, &(&1.type == "mdat"))
    check_integrity!(mdats)
    originals = collect_tables(boxes)

    if originals == [] do
      boxes
    else
      boxes
      |> converge(originals, threshold, MapSet.new(), 0)
      |> rebase_mdats()
    end
  end

  @doc """
  Move `moov` to immediately after any leading `ftyp` (and before `mdat`), then fix
  chunk offsets. Returns the tree unchanged if it has no `moov` or no `mdat`.
  """
  def faststart(boxes, opts \\ []) when is_list(boxes) do
    has_moov = Enum.any?(boxes, &(&1.type == "moov"))
    has_mdat = Enum.any?(boxes, &(&1.type == "mdat"))

    if has_moov and has_mdat do
      boxes |> move_moov_first() |> fix_chunk_offsets(opts)
    else
      boxes
    end
  end

  # --- faststart rearrangement ---

  defp move_moov_first(boxes) do
    moov = Enum.find(boxes, &(&1.type == "moov"))
    without = Enum.reject(boxes, &(&1.type == "moov"))
    {leading_ftyp, rest} = Enum.split_while(without, &(&1.type == "ftyp"))
    leading_ftyp ++ [moov] ++ rest
  end

  # --- integrity ---

  defp check_integrity!(mdats) do
    Enum.each(mdats, fn m ->
      cond do
        is_nil(m.source_offset) or is_nil(m.source_size) ->
          raise ArgumentError,
                "fix_chunk_offsets: an mdat has no source position (synthesized?). " <>
                  "Sample-level editing is not supported in this phase."

        Layout.box_size(m) != m.source_size ->
          raise ArgumentError,
                "fix_chunk_offsets: an mdat changed size since parsing " <>
                  "(#{Layout.box_size(m)} vs #{m.source_size}). Sample-level editing " <>
                  "is out of scope."

        true ->
          :ok
      end
    end)
  end

  # --- fixpoint ---

  defp converge(_tree, _originals, _threshold, _promoted, iter) when iter > @max_iterations do
    raise ArgumentError, "fix_chunk_offsets: failed to converge after #{@max_iterations} iterations"
  end

  defp converge(tree, originals, threshold, promoted, iter) do
    {new_tree, new_promoted} = apply_offsets(tree, originals, threshold, promoted)

    if signatures(new_tree) == signatures(tree) do
      new_tree
    else
      converge(new_tree, originals, threshold, new_promoted, iter + 1)
    end
  end

  defp apply_offsets(tree, originals, threshold, promoted) do
    ranges = mdat_ranges(tree)
    {new_tree, {_i, new_promoted}} = walk_apply(tree, originals, ranges, threshold, {0, promoted})
    {new_tree, new_promoted}
  end

  # Each mdat's {old_start, old_end, delta}. old_* from the mdat's own source_*
  # (the basis the current offsets were written against); delta from its new
  # payload position in the current layout.
  defp mdat_ranges(tree) do
    tree
    |> Layout.top_level_layout()
    |> Enum.filter(&(&1.box.type == "mdat"))
    |> Enum.map(fn %{box: m, payload_offset: new_payload_start} ->
      old_payload_start = m.source_offset + Layout.header_size(m)
      {m.source_offset, m.source_offset + m.source_size, new_payload_start - old_payload_start}
    end)
  end

  # Walk the tree in document order, replacing the i-th stco/co64 box with its
  # remapped version. `originals` (same traversal order) supplies the basis offsets
  # so remapping is computed against a stable reference each iteration.
  defp walk_apply(boxes, originals, ranges, threshold, acc) do
    Enum.map_reduce(boxes, acc, fn box, {i, promoted} ->
      cond do
        box.type in ["stco", "co64"] ->
          orig = Enum.at(originals, i)
          new_offsets = Enum.map(orig.offsets, &(&1 + delta_for!(ranges, &1)))
          overflow? = Enum.any?(new_offsets, &(&1 > threshold))
          promoted = if overflow?, do: MapSet.put(promoted, i), else: promoted
          kind = if MapSet.member?(promoted, i), do: :co64, else: orig.kind

          new_box =
            ChunkOffset.encode(%ChunkOffset{
              kind: kind,
              version: orig.version,
              flags: orig.flags,
              offsets: new_offsets
            })

          {new_box, {i + 1, promoted}}

        box.data == nil ->
          {children, acc2} = walk_apply(box.children, originals, ranges, threshold, {i, promoted})
          {%{box | children: children}, acc2}

        true ->
          {box, {i, promoted}}
      end
    end)
  end

  defp delta_for!(ranges, offset) do
    case Enum.find(ranges, fn {s, e, _d} -> offset >= s and offset < e end) do
      {_s, _e, delta} ->
        delta

      nil ->
        raise ArgumentError,
              "fix_chunk_offsets: chunk offset #{offset} falls outside every mdat; cannot remap"
    end
  end

  # Update each top-level mdat's source_offset to its position in the final layout,
  # so the offsets now in the tree are consistent with the recorded basis. This is
  # what makes fix_chunk_offsets idempotent and composable across edits.
  defp rebase_mdats(tree) do
    new_offsets =
      tree
      |> Layout.top_level_layout()
      |> Enum.filter(&(&1.box.type == "mdat"))
      |> Enum.map(& &1.offset)

    {rebased, []} =
      Enum.map_reduce(tree, new_offsets, fn box, offs ->
        case {box.type, offs} do
          {"mdat", [o | rest]} -> {%{box | source_offset: o}, rest}
          _ -> {box, offs}
        end
      end)

    rebased
  end

  # Decoded chunk-offset tables in document order (matches walk_apply's order).
  defp collect_tables(boxes) do
    Enum.flat_map(boxes, fn box ->
      cond do
        box.type in ["stco", "co64"] -> [ChunkOffset.decode(box)]
        box.data == nil -> collect_tables(box.children)
        true -> []
      end
    end)
  end

  # {type, data} of each chunk-offset box in document order — used for fixpoint
  # stability comparison.
  defp signatures(boxes) do
    Enum.flat_map(boxes, fn box ->
      cond do
        box.type in ["stco", "co64"] -> [{box.type, box.data}]
        box.data == nil -> signatures(box.children)
        true -> []
      end
    end)
  end
end
