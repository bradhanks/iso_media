defmodule ISOMedia.MdatSource do
  @moduledoc """
  Resolves an absolute file byte range to a payload segment, given the top-level
  `mdat` boxes of a parsed tree. Returns a `%FileSlice{}` when the containing `mdat`
  is lazy, or a `binary` slice when it is in memory. Shared by `Extract` and `Trim`.
  """

  alias ISOMedia.{FileSlice, Layout}

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

  defp resolve(parts, _relative, _length) when is_list(parts) do
    raise ArgumentError, "segment-list resolution not yet implemented"
  end
end
