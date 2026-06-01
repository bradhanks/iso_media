defmodule ISOMedia.MP4BuilderTest do
  use ExUnit.Case
  alias ISOMedia.Support.MP4Builder

  test "builds a parseable mp4 whose stco offsets point at the chunk bytes" do
    chunks = [<<1, 2, 3>>, <<4, 5>>, <<6>>]
    %{binary: bin, offsets: offsets} = MP4Builder.build(chunks)

    assert {:ok, boxes} = ISOMedia.parse(bin)
    assert ISOMedia.serialize(boxes) == bin

    stco = ISOMedia.Box.find(boxes, ~w(moov trak mdia minf stbl stco))
    assert ISOMedia.Boxes.ChunkOffset.decode(stco).offsets == offsets

    Enum.zip(chunks, offsets)
    |> Enum.each(fn {chunk, off} -> assert binary_part(bin, off, byte_size(chunk)) == chunk end)
  end
end
