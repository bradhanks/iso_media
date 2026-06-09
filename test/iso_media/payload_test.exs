defmodule ISOMedia.PayloadTest do
  use ExUnit.Case
  alias ISOMedia.{FileSlice, Payload}

  setup do
    path = Path.join(System.tmp_dir!(), "iso_payload_#{System.unique_integer([:positive])}.bin")
    File.write!(path, <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  describe "size/1" do
    test "binary, FileSlice, and nested segment list", %{path: path} do
      assert Payload.size(<<0, 0, 0>>) == 3
      assert Payload.size(%FileSlice{path: path, offset: 0, length: 4}) == 4

      parts = [<<0, 0>>, %FileSlice{path: path, offset: 0, length: 4}, [<<0>>, <<0, 0, 0>>]]
      assert Payload.size(parts) == 2 + 4 + 4
    end
  end

  describe "read/1" do
    test "concatenates binaries, slices, and nested lists in order", %{path: path} do
      parts = [<<9, 9>>, %FileSlice{path: path, offset: 2, length: 3}, [<<7>>, <<6, 5>>]]
      assert Payload.read(parts) == <<9, 9, 2, 3, 4, 7, 6, 5>>
    end

    test "a bare FileSlice reads its bytes", %{path: path} do
      assert Payload.read(%FileSlice{path: path, offset: 5, length: 3}) == <<5, 6, 7>>
    end
  end

  describe "slice/3" do
    test "a FileSlice yields a windowed FileSlice (no disk read)", %{path: path} do
      fs = %FileSlice{path: path, offset: 10, length: 100}
      assert Payload.slice(fs, 5, 20) == %FileSlice{path: path, offset: 15, length: 20}
    end

    test "a binary yields a binary_part" do
      assert Payload.slice(<<0, 1, 2, 3, 4, 5>>, 2, 3) == <<2, 3, 4>>
    end

    test "a range within one segment returns that slice bare", %{path: path} do
      parts = [<<0, 1, 2, 3>>, %FileSlice{path: path, offset: 0, length: 4}]
      assert Payload.slice(parts, 1, 2) == <<1, 2>>
    end

    test "a range spanning segments returns a sub-segment list", %{path: path} do
      parts = [<<0, 1, 2, 3>>, %FileSlice{path: path, offset: 0, length: 4}]
      # bytes [2, 6) -> tail of the binary (2,3) + head of the slice (offset 0, len 2)
      assert Payload.slice(parts, 2, 4) == [<<2, 3>>, %FileSlice{path: path, offset: 0, length: 2}]
    end

    test "slicing a synthesized segment list is read-equivalent to slicing its bytes", %{path: path} do
      parts = [<<10, 11>>, %FileSlice{path: path, offset: 0, length: 6}, [<<20>>, <<21, 22>>]]
      whole = Payload.read(parts)

      for {lo, len} <- [{0, 11}, {1, 3}, {2, 7}, {8, 3}, {0, 1}] do
        assert Payload.read(Payload.slice(parts, lo, len)) == binary_part(whole, lo, len)
      end
    end
  end

  describe "slice_paths/1" do
    test "collects FileSlice paths, ignoring in-memory bytes", %{path: path} do
      other = path <> ".other"
      parts = [<<0>>, %FileSlice{path: path, offset: 0, length: 1}, [%FileSlice{path: other, offset: 0, length: 1}]]
      assert Payload.slice_paths(parts) == [path, other]
      assert Payload.slice_paths(<<0, 0>>) == []
      assert Payload.slice_paths(%FileSlice{path: path, offset: 0, length: 1}) == [path]
    end
  end
end
