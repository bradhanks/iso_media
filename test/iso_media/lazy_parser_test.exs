defmodule ISOMedia.LazyParserTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FileSlice, LazyParser}

  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  setup do
    # ftyp (small leaf) + moov (container w/ small mvhd) + mdat (big leaf)
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    moov = container("moov", leaf("mvhd", <<0, 1, 2, 3>>))
    big = :binary.copy(<<7>>, 5000)
    mdat = leaf("mdat", big)
    bin = ftyp <> moov <> mdat

    path = Path.join(System.tmp_dir!(), "iso_lazy_#{System.unique_integer([:positive])}.mp4")
    File.write!(path, bin)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path, bin: bin, big: big, ftyp: ftyp, moov: moov}
  end

  test "big leaf becomes a FileSlice; small leaf and container stay in memory", ctx do
    assert {:ok, boxes} = LazyParser.parse_file(ctx.path, lazy_threshold: 1000)
    [ftyp_box, moov_box, mdat_box] = boxes

    assert is_binary(ftyp_box.data)
    assert ftyp_box.type == "ftyp"

    assert moov_box.data == nil
    assert [%Box{type: "mvhd", data: <<0, 1, 2, 3>>}] = moov_box.children

    assert %FileSlice{path: p, length: 5000} = mdat_box.data
    assert p == ctx.path
    assert FileSlice.read(mdat_box.data) == ctx.big
  end

  test "source_offset/source_size match the eager parser (incl. nested)", ctx do
    {:ok, lazy} = LazyParser.parse_file(ctx.path, lazy_threshold: 1000)
    {:ok, eager} = ISOMedia.parse(ctx.bin)

    offsets = fn boxes ->
      Enum.map(boxes, fn b ->
        {b.type, b.source_offset, b.source_size,
         Enum.map(b.children, &{&1.type, &1.source_offset})}
      end)
    end

    assert offsets.(lazy) == offsets.(eager)
  end

  test "serialize of a lazy tree equals the original bytes", ctx do
    {:ok, boxes} = LazyParser.parse_file(ctx.path, lazy_threshold: 1000)
    assert ISOMedia.Serializer.serialize(boxes) == ctx.bin
  end

  test "a size-0 (eof) mdat resolves its length from the file size" do
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    big = :binary.copy(<<3>>, 2000)
    # size field 0 → runs to EOF
    eof_mdat = <<0::32, "mdat", big::binary>>
    bin = ftyp <> eof_mdat
    path = Path.join(System.tmp_dir!(), "iso_lazy_eof_#{System.unique_integer([:positive])}.mp4")
    File.write!(path, bin)
    on_exit(fn -> File.rm(path) end)

    {:ok, boxes} = LazyParser.parse_file(path, lazy_threshold: 1000)
    [_ftyp, mdat_box] = boxes
    assert mdat_box.size_mode == :eof
    assert %FileSlice{length: 2000} = mdat_box.data
    # round-trips byte-for-byte (the size-0 box re-emits size field 0)
    assert ISOMedia.Serializer.serialize(boxes) == bin
  end
end
