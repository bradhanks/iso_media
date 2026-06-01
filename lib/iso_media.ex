defmodule ISOMedia do
  @moduledoc """
  Lossless ISOBMFF (MP4/MOV/M4A/HEIF) box surgery.

      iex> {:ok, boxes} = ISOMedia.parse(<<8::32, "free">>)
      iex> ISOMedia.serialize(boxes)
      <<8::32, "free">>
  """

  alias ISOMedia.{Parser, Serializer}

  @doc "Parse a binary into `{:ok, [%ISOMedia.Box{}]}`. See `ISOMedia.Parser.parse/2`."
  def parse(binary, opts \\ []), do: Parser.parse(binary, opts)

  @doc "Serialize a box or list of boxes back to a binary."
  def serialize(boxes), do: Serializer.serialize(boxes)

  @doc "Recompute stco/co64 chunk offsets for the current box arrangement. See `ISOMedia.Offsets.fix_chunk_offsets/1`."
  def fix_chunk_offsets(boxes), do: ISOMedia.Offsets.fix_chunk_offsets(boxes)

  @doc "Move `moov` before `mdat` (faststart) and fix chunk offsets. See `ISOMedia.Offsets.faststart/1`."
  def faststart(boxes), do: ISOMedia.Offsets.faststart(boxes)

  @doc "Read a file and parse it."
  def read(path, opts \\ []) do
    with {:ok, binary} <- File.read(path), do: parse(binary, opts)
  end

  @doc "Serialize boxes and write them to a file (streams iodata, no full-binary copy)."
  def write(path, boxes), do: File.write(path, ISOMedia.Serializer.to_iodata(boxes))
end
