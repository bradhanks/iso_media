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
end
