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

  @doc "A segment (FileSlice or binary) for the absolute `offset`..`offset+length` range."
  def segment(mdats, offset, length) do
    mdat =
      Enum.find(mdats, fn m ->
        not is_nil(m.source_offset) and offset >= m.source_offset and
          offset < m.source_offset + m.source_size
      end) || raise ArgumentError, "byte range at offset #{offset} falls outside every mdat"

    case mdat.data do
      %FileSlice{path: path} ->
        %FileSlice{path: path, offset: offset, length: length}

      bin when is_binary(bin) ->
        %Box{} = mdat
        binary_part(bin, offset - (mdat.source_offset + Layout.header_size(mdat)), length)

      _ ->
        raise ArgumentError, "cannot read from an mdat whose payload is already a segment list"
    end
  end
end
