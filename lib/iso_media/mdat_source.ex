defmodule ISOMedia.MdatSource do
  @moduledoc """
  Resolves an absolute file byte range to a payload segment, given the top-level
  `mdat` boxes of a parsed tree. Returns a `%FileSlice{}` when the containing `mdat`
  is lazy, or a `binary` slice when it is in memory. Shared by `Extract` and `Trim`.
  """

  alias ISOMedia.{Box, FileSlice, Layout}

  @doc "The top-level `mdat` boxes of `boxes`."
  def collect(boxes), do: Enum.filter(boxes, &(&1.type == "mdat"))

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
