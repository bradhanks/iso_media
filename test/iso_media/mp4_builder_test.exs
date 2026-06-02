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

  test "build_tracks produces a parseable multi-track file with a correct sample index" do
    # Track 7: 2 chunks ([s1,s2],[s3]); Track 8: 1 chunk ([s4,s5]). Distinct marker bytes.
    specs = [
      %{id: 7, chunks: [[<<1, 1>>, <<2, 2, 2>>], [<<3>>]]},
      %{id: 8, chunks: [[<<4, 4, 4, 4>>, <<5>>]]}
    ]

    %{binary: bin} = ISOMedia.Support.MP4Builder.build_tracks(specs)
    assert {:ok, boxes} = ISOMedia.parse(bin)
    assert ISOMedia.serialize(boxes) == bin
    assert Enum.sort(ISOMedia.track_ids(boxes)) == [7, 8]

    # Track 7's samples resolve to the exact marker bytes.
    s7 = ISOMedia.samples(boxes, 7)
    assert Enum.map(s7, & &1.size) == [2, 3, 1]
    assert Enum.map(s7, &binary_part(bin, &1.offset, &1.size)) == [<<1, 1>>, <<2, 2, 2>>, <<3>>]

    s8 = ISOMedia.samples(boxes, 8)
    assert Enum.map(s8, &binary_part(bin, &1.offset, &1.size)) == [<<4, 4, 4, 4>>, <<5>>]
  end
end
