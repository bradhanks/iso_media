defmodule ISOMedia.MdatSourceTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FileSlice, MdatSource}

  test "segment/3 returns binary_part for an eager mdat" do
    # mdat at source_offset 100, 8-byte header, payload <<0..15>>
    payload = for(i <- 0..15, into: <<>>, do: <<i>>)
    mdat = %Box{type: "mdat", data: payload, source_offset: 100, source_size: 8 + 16}
    # absolute offset 108 = payload start; read 4 bytes
    assert MdatSource.segment([mdat], 108, 4) == <<0, 1, 2, 3>>
    assert MdatSource.segment([mdat], 110, 2) == <<2, 3>>
  end

  test "segment/3 returns a FileSlice for a lazy mdat" do
    mdat = %Box{
      type: "mdat",
      data: %FileSlice{path: "x", offset: 0, length: 16},
      source_offset: 100,
      source_size: 24
    }

    assert MdatSource.segment([mdat], 110, 3) == %FileSlice{path: "x", offset: 110, length: 3}
  end

  test "segment/3 raises when offset is outside every mdat" do
    mdat = %Box{type: "mdat", data: <<0, 1, 2, 3>>, source_offset: 100, source_size: 12}
    assert_raise ArgumentError, fn -> MdatSource.segment([mdat], 9999, 2) end
  end
end
