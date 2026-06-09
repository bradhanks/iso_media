defmodule ISOMedia.SerializerTest do
  use ExUnit.Case
  alias ISOMedia.{Parser, Serializer}

  defp round_trips!(bin) do
    {:ok, boxes} = Parser.parse(bin)
    assert Serializer.serialize(boxes) == bin
  end

  test "round-trips a compact leaf" do
    round_trips!(<<12::32, "free", 1, 2, 3, 4>>)
  end

  test "round-trips siblings" do
    round_trips!(<<8::32, "free", 9::32, "skip", 0>>)
  end

  test "round-trips a nested container" do
    inner = <<8::32, "mvhd", 8::32, "free">>
    round_trips!(<<8 + byte_size(inner)::32, "moov", inner::binary>>)
  end

  test "round-trips a 64-bit largesize box" do
    round_trips!(<<1::32, "mdat", 20::64, 9, 9, 9, 9>>)
  end

  test "round-trips a size-0 box" do
    round_trips!(<<0::32, "mdat", 7, 7, 7>>)
  end

  test "round-trips a uuid box" do
    round_trips!(<<27::32, "uuid", 0::128, 1, 2, 3>>)
  end

  test "serialize/1 accepts a single box" do
    {:ok, [box]} = Parser.parse(<<8::32, "free">>)
    assert Serializer.serialize(box) == <<8::32, "free">>
  end

  test "serializing a box with both data and children raises" do
    bad = %ISOMedia.Box{
      type: "moov",
      data: <<1>>,
      children: [%ISOMedia.Box{type: "free", data: ""}]
    }

    assert_raise ArgumentError, fn -> ISOMedia.Serializer.serialize([bad]) end
  end

  test "to_iodata returns iodata equal in bytes to serialize/1" do
    boxes = [
      %ISOMedia.Box{type: "free", data: <<1, 2, 3>>},
      %ISOMedia.Box{type: "mdat", data: <<9>>}
    ]

    iodata = ISOMedia.Serializer.to_iodata(boxes)
    assert IO.iodata_to_binary(iodata) == ISOMedia.Serializer.serialize(boxes)
  end

  test "to_iodata accepts a single box" do
    box = %ISOMedia.Box{type: "free", data: <<>>}
    assert IO.iodata_to_binary(ISOMedia.Serializer.to_iodata(box)) == <<8::32, "free">>
  end

  describe "FileSlice handling" do
    setup do
      path = Path.join(System.tmp_dir!(), "iso_ser_#{System.unique_integer([:positive])}.bin")
      File.write!(path, <<10, 11, 12, 13>>)
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "materialize/1 replaces a FileSlice leaf with its bytes", %{path: path} do
      box = %ISOMedia.Box{
        type: "mdat",
        data: %ISOMedia.FileSlice{path: path, offset: 0, length: 4}
      }

      [materialized] = ISOMedia.Serializer.materialize([box])
      assert materialized.data == <<10, 11, 12, 13>>
    end

    test "serialize/1 materializes a lazy tree to the right bytes", %{path: path} do
      box = %ISOMedia.Box{
        type: "mdat",
        data: %ISOMedia.FileSlice{path: path, offset: 0, length: 4}
      }

      # size 12 (8 header + 4 payload), type mdat, then the 4 bytes
      assert ISOMedia.Serializer.serialize([box]) == <<12::32, "mdat", 10, 11, 12, 13>>
    end

    test "to_iodata/1 raises a clear error on an un-materialized FileSlice", %{path: path} do
      box = %ISOMedia.Box{
        type: "mdat",
        data: %ISOMedia.FileSlice{path: path, offset: 0, length: 4}
      }

      assert_raise ArgumentError, ~r/FileSlice/, fn -> ISOMedia.Serializer.to_iodata([box]) end
    end
  end

  describe "stream/3" do
    test "streams an in-memory tree byte-identically to serialize/1" do
      boxes = [
        %ISOMedia.Box{type: "ftyp", data: <<"isom", 0::32, "isom">>},
        %ISOMedia.Box{type: "moov", children: [%ISOMedia.Box{type: "mvhd", data: <<0, 1, 2>>}]},
        %ISOMedia.Box{type: "mdat", data: <<9, 9, 9, 9>>}
      ]

      out = Path.join(System.tmp_dir!(), "iso_stream_#{System.unique_integer([:positive])}.bin")
      on_exit(fn -> File.rm(out) end)

      File.open!(out, [:write, :binary, :raw], fn io ->
        :ok = ISOMedia.Serializer.stream(boxes, io)
      end)

      assert File.read!(out) == ISOMedia.Serializer.serialize(boxes)
    end

    test "streams a FileSlice leaf from disk" do
      src =
        Path.join(System.tmp_dir!(), "iso_stream_src_#{System.unique_integer([:positive])}.bin")

      File.write!(src, <<7, 7, 7, 7, 7, 7>>)

      out =
        Path.join(System.tmp_dir!(), "iso_stream_out_#{System.unique_integer([:positive])}.bin")

      on_exit(fn ->
        File.rm(src)
        File.rm(out)
      end)

      box = %ISOMedia.Box{
        type: "mdat",
        data: %ISOMedia.FileSlice{path: src, offset: 1, length: 4}
      }

      File.open!(out, [:write, :binary, :raw], fn io ->
        ISOMedia.Serializer.stream([box], io, 2)
      end)

      # size 12 (8 + 4), type mdat, then bytes src[1..4]
      assert File.read!(out) == <<12::32, "mdat", 7, 7, 7, 7>>
    end
  end

  describe "header_bytes/1" do
    alias ISOMedia.{Box, Layout, Serializer}

    test "returns size+type bytes whose length equals header_size for a compact box" do
      box = %Box{type: "free", data: <<1, 2, 3, 4>>, size_mode: :compact}
      bytes = Serializer.header_bytes(box)
      assert bytes == <<12::32, "free">>
      assert byte_size(bytes) == Layout.header_size(box)
    end

    test "appends the 16 uuid bytes after the header for an extended-type box" do
      uuid = :binary.copy(<<0xAB>>, 16)
      box = %Box{type: "uuid", uuid: uuid, data: <<9, 9>>, size_mode: :compact}
      bytes = Serializer.header_bytes(box)
      # size field counts header(8) + uuid(16) + payload(2) = 26; then type; then uuid.
      assert bytes == <<26::32, "uuid", uuid::binary>>
      assert byte_size(bytes) == Layout.header_size(box)
    end

    test "uses the 16-byte largesize header for :large size_mode" do
      box = %Box{type: "mdat", data: <<9, 9, 9, 9>>, size_mode: :large}
      bytes = Serializer.header_bytes(box)
      # large header: size field == 1, then type, then 64-bit largesize (16 header + 4 payload).
      assert bytes == <<1::32, "mdat", 20::64>>
      assert byte_size(bytes) == Layout.header_size(box)
    end
  end

  describe "segment-list payload" do
    setup do
      path = Path.join(System.tmp_dir!(), "iso_seg_#{System.unique_integer([:positive])}.bin")
      File.write!(path, <<0, 1, 2, 3, 4, 5, 6, 7>>)
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "box_size sums binary + FileSlice parts", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      box = %ISOMedia.Box{type: "mdat", data: parts}
      # header 8 + (2 + 3)
      assert ISOMedia.Layout.box_size(box) == 13
    end

    test "serialize materializes a segment list", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      box = %ISOMedia.Box{type: "mdat", data: parts}
      assert ISOMedia.Serializer.serialize([box]) == <<13::32, "mdat", 9, 9, 2, 3, 4>>
    end

    test "stream writes each segment in order", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      box = %ISOMedia.Box{type: "mdat", data: parts}
      out = Path.join(System.tmp_dir!(), "iso_seg_out_#{System.unique_integer([:positive])}.bin")
      on_exit(fn -> File.rm(out) end)

      File.open!(out, [:write, :binary, :raw], fn io ->
        ISOMedia.Serializer.stream([box], io, 2)
      end)

      assert File.read!(out) == <<13::32, "mdat", 9, 9, 2, 3, 4>>
    end

    test "read_data concatenates the parts", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      assert ISOMedia.Box.read_data(%ISOMedia.Box{type: "mdat", data: parts}) == <<9, 9, 2, 3, 4>>
    end

    test "to_iodata raises on a raw segment list", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      box = %ISOMedia.Box{type: "mdat", data: parts}
      assert_raise ArgumentError, ~r/segment list/, fn -> ISOMedia.Serializer.to_iodata([box]) end
    end

    test "serialize materializes a nested segment list in order", %{path: path} do
      # data is [binary, [binary, FileSlice]] — one level of nesting.
      box = %ISOMedia.Box{
        type: "mdat",
        data: [<<0, 1>>, [<<2, 3>>, %ISOMedia.FileSlice{path: path, offset: 1, length: 2}]]
      }

      # payload = <<0,1>> ++ <<2,3>> ++ path[1..2]=<<1,2>>  -> 6 bytes; size 14
      assert ISOMedia.Serializer.serialize([box]) == <<14::32, "mdat", 0, 1, 2, 3, 1, 2>>
    end

    test "stream writes a nested segment list identically to serialize", %{path: path} do
      box = %ISOMedia.Box{
        type: "mdat",
        data: [<<0, 1>>, [<<2, 3>>, %ISOMedia.FileSlice{path: path, offset: 1, length: 2}]]
      }

      out =
        Path.join(System.tmp_dir!(), "iso_seg_nested_#{System.unique_integer([:positive])}.bin")

      on_exit(fn -> File.rm(out) end)

      File.open!(out, [:write, :binary, :raw], fn io ->
        ISOMedia.Serializer.stream([box], io, 2)
      end)

      assert File.read!(out) == ISOMedia.Serializer.serialize([box])
    end
  end
end
