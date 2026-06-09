defmodule ISOMedia.Boxes.ChunkOffsetTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.ChunkOffset

  test "decodes a stco box (32-bit entries)" do
    data = <<0, 0, 0, 0, 3::32, 100::32, 200::32, 300::32>>
    co = ChunkOffset.decode(%Box{type: "stco", data: data})
    assert co.kind == :stco
    assert co.version == 0
    assert co.flags == <<0, 0, 0>>
    assert co.offsets == [100, 200, 300]
  end

  test "decodes a co64 box (64-bit entries)" do
    data = <<0, 0, 0, 0, 2::32, 5_000_000_000::64, 6_000_000_000::64>>
    co = ChunkOffset.decode(%Box{type: "co64", data: data})
    assert co.kind == :co64
    assert co.offsets == [5_000_000_000, 6_000_000_000]
  end

  test "stco round-trips" do
    box = %Box{type: "stco", data: <<0, 0, 0, 0, 2::32, 10::32, 20::32>>}
    assert ChunkOffset.encode(ChunkOffset.decode(box)) == box
  end

  test "co64 round-trips" do
    box = %Box{type: "co64", data: <<0, 0, 0, 0, 1::32, 9_000_000_000::64>>}
    assert ChunkOffset.encode(ChunkOffset.decode(box)) == box
  end

  test "encode regenerates entry_count" do
    co = %ChunkOffset{kind: :stco, version: 0, flags: <<0, 0, 0>>, offsets: [1, 2, 3, 4]}
    %Box{data: <<_v, _f::binary-size(3), count::32, _rest::binary>>} = ChunkOffset.encode(co)
    assert count == 4
  end

  test "kind_for/1 picks co64 once an offset exceeds the 32-bit stco field" do
    assert ChunkOffset.kind_for(0) == :stco
    assert ChunkOffset.kind_for(0xFFFFFFFF) == :stco
    assert ChunkOffset.kind_for(0xFFFFFFFF + 1) == :co64
  end
end
