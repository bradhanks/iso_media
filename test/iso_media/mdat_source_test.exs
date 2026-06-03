defmodule ISOMedia.MdatSourceTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FileSlice, MdatSource}

  describe "collect/1" do
    test "captures payload_start/payload_size from the layout walk" do
      ftyp = %Box{type: "ftyp", size_mode: :compact, data: <<0, 0, 0, 0>>}
      mdat = %Box{type: "mdat", size_mode: :compact, data: <<0, 1, 2, 3, 4, 5, 6, 7>>}

      # ftyp: 8 header + 4 payload = 12. mdat starts at 12, payload at 12+8 = 20.
      assert [%{box: ^mdat, payload_start: 20, payload_size: 8}] =
               MdatSource.collect([ftyp, mdat])
    end

    test "captures multiple mdats in order" do
      a = %Box{type: "mdat", size_mode: :compact, data: <<0, 0, 0, 0>>}
      free = %Box{type: "free", size_mode: :compact, data: <<0, 0>>}
      b = %Box{type: "mdat", size_mode: :compact, data: <<9, 9, 9>>}

      # a: 12 bytes (payload at 8). free: 10 bytes (starts at 12). b: starts at 22, payload at 30.
      assert [%{payload_start: 8, payload_size: 4}, %{payload_start: 30, payload_size: 3}] =
               MdatSource.collect([a, free, b])
    end
  end

  describe "segment/3 leaves" do
    test "binary mdat returns a binary_part at the relative offset" do
      mdat = %Box{type: "mdat", size_mode: :compact, data: for(i <- 0..15, into: <<>>, do: <<i>>)}
      [rec] = MdatSource.collect([mdat])
      # payload_start is 8; absolute offset 8 == relative 0
      assert MdatSource.segment([rec], 8, 4) == <<0, 1, 2, 3>>
      assert MdatSource.segment([rec], 10, 2) == <<2, 3>>
    end

    test "FileSlice mdat resolves fs.offset + relative (decoupled from absolute target)" do
      # The mdat payload lives on disk starting at byte 1000, even though in this tree
      # its captured payload_start is 8. Resolution must use fs.offset + relative = 1000 + 2.
      mdat = %Box{
        type: "mdat",
        size_mode: :compact,
        data: %FileSlice{path: "src", offset: 1000, length: 16}
      }

      [rec] = MdatSource.collect([mdat])
      assert MdatSource.segment([rec], 10, 3) == %FileSlice{path: "src", offset: 1002, length: 3}
    end

    test "raises when offset falls outside every mdat" do
      mdat = %Box{type: "mdat", size_mode: :compact, data: <<0, 1, 2, 3>>}
      recs = MdatSource.collect([mdat])
      assert_raise ArgumentError, fn -> MdatSource.segment(recs, 9999, 2) end
    end
  end

  describe "segment/3 segment lists" do
    defp seglist_mdat(parts) do
      mdat = %Box{type: "mdat", size_mode: :compact, data: parts}
      MdatSource.collect([mdat])
    end

    test "range within a single part returns that part's slice (bare, not wrapped)" do
      recs = seglist_mdat([<<0, 1, 2, 3>>, <<4, 5, 6, 7>>])
      # payload_start 8. Absolute 9 -> relative 1, within part 0.
      assert MdatSource.segment(recs, 9, 2) == <<1, 2>>
    end

    test "range spanning two parts returns a list of the two slices" do
      recs = seglist_mdat([<<0, 1, 2, 3>>, <<4, 5, 6, 7>>])
      # relative 2..6 -> [<<2,3>>, <<4,5>>]
      assert MdatSource.segment(recs, 10, 4) == [<<2, 3>>, <<4, 5>>]
    end

    test "slices a FileSlice part by adding the in-part start to fs.offset" do
      recs = seglist_mdat([<<0, 1>>, %FileSlice{path: "x", offset: 500, length: 6}])
      # relative 3 -> part 1, in-part start 1 -> fs.offset 500+1, length 4
      assert MdatSource.segment(recs, 11, 4) == %FileSlice{path: "x", offset: 501, length: 4}
    end

    test "recurses through a nested segment list, preserving nesting in the result" do
      # parts: [<<0,1>>, [<<2,3>>, %FileSlice{...len 4}]] — total payload 8 bytes
      nested = [<<2, 3>>, %FileSlice{path: "y", offset: 0, length: 4}]
      recs = seglist_mdat([<<0, 1>>, nested])
      # relative 1..8 (7 bytes) -> part0 tail <<1>>, then into nested: <<2,3>> + fs[0,4]
      assert MdatSource.segment(recs, 9, 7) ==
               [<<1>>, [<<2, 3>>, %FileSlice{path: "y", offset: 0, length: 4}]]
    end
  end
end
