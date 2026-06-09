defmodule ISOMedia.MdatSource do
  @moduledoc """
  Resolves an absolute file byte range to a payload segment, given the top-level
  `mdat` boxes of a parsed tree. Returns a `%FileSlice{}` when the containing `mdat`
  is lazy, or a `binary` slice when it is in memory. Shared by `Extract` and `Trim`.
  """

  alias ISOMedia.{Box, FileSlice, Layout}

  @doc """
  Capture each top-level `mdat`'s absolute payload range from a single `Layout` walk:
  `[%{box: mdat, payload_start: abs, payload_size: len}]`. The walk uses the same
  `Layout.box_size/1` the serializer uses, so the offsets are byte-identical to the
  written file — the basis for drift-free recursive resolution.
  """
  def collect(boxes) do
    {records, _end_off} =
      Enum.flat_map_reduce(boxes, 0, fn box, off ->
        size = Layout.box_size(box)

        records =
          if box.type == "mdat" do
            header = Layout.header_size(box)
            [%{box: box, payload_start: off + header, payload_size: size - header}]
          else
            []
          end

        {records, off + size}
      end)

    records
  end

  @doc """
  Build a synthesized segment-list `mdat`, stamped with the basis position its chunk
  offsets were written against. `payload_start` is the absolute byte offset of the mdat
  payload in the layout its offsets were baked for (what the builder already computed to
  place chunks). The stamp gives `ISOMedia.Offsets.fix_chunk_offsets/1` a basis, so the
  table can be remapped if the mdat later moves — no disk round-trip needed.
  """
  def synthesized_mdat(segments, size_mode, payload_start) do
    box = %Box{type: "mdat", data: segments, size_mode: size_mode}

    %{
      box
      | source_offset: payload_start - Layout.header_size(box),
        source_size: Layout.box_size(box)
    }
  end

  @doc """
  Resolve the absolute `offset`..`offset+length` range to a payload segment, given the
  records from `collect/1`. Returns a `binary`, a `%FileSlice{}`, or (for a segment-list
  mdat) a nested segment list. Uses `relative = offset - payload_start`, so a physical
  `FileSlice` acts as a local byte provider (`fs.offset + relative`) independent of the
  absolute target.
  """
  def segment(records, offset, length) do
    rec =
      Enum.find(records, fn r ->
        offset >= r.payload_start and offset < r.payload_start + r.payload_size
      end) || raise ArgumentError, "byte range at offset #{offset} falls outside every mdat"

    resolve(rec.box.data, offset - rec.payload_start, length)
  end

  defp resolve(%FileSlice{path: path, offset: base}, relative, length) do
    %FileSlice{path: path, offset: base + relative, length: length}
  end

  defp resolve(bin, relative, length) when is_binary(bin) do
    binary_part(bin, relative, length)
  end

  defp resolve(parts, relative, length) when is_list(parts) do
    resolve_in_segments(parts, relative, length)
  end

  # Walk parts accumulating their byte lengths; slice each part overlapping
  # [lo, lo+len). One overlapping part -> return its slice bare; several -> a list.
  defp resolve_in_segments(parts, lo, len) do
    hi = lo + len

    {slices, _pos} =
      Enum.flat_map_reduce(parts, 0, fn part, pos ->
        part_len = Layout.segment_size(part)
        part_hi = pos + part_len

        if part_hi <= lo or pos >= hi do
          {[], part_hi}
        else
          start = max(lo, pos) - pos
          take = min(hi, part_hi) - max(lo, pos)
          {[slice_part(part, start, take)], part_hi}
        end
      end)

    case slices do
      [one] -> one
      many -> many
    end
  end

  defp slice_part(%FileSlice{path: p, offset: o}, start, take) do
    %FileSlice{path: p, offset: o + start, length: take}
  end

  defp slice_part(bin, start, take) when is_binary(bin) do
    binary_part(bin, start, take)
  end

  defp slice_part(parts, start, take) when is_list(parts) do
    resolve_in_segments(parts, start, take)
  end
end
