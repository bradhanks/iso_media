defmodule ISOMediaTest do
  use ExUnit.Case
  doctest ISOMedia

  @bin <<12::32, "free", 1, 2, 3, 4>>

  test "parse/1 and serialize/1 round-trip" do
    assert {:ok, boxes} = ISOMedia.parse(@bin)
    assert ISOMedia.serialize(boxes) == @bin
  end

  test "read/1 and write/2 round-trip via a temp file" do
    path = Path.join(System.tmp_dir!(), "iso_media_rt.bin")
    File.write!(path, @bin)
    assert {:ok, boxes} = ISOMedia.read(path)
    out = Path.join(System.tmp_dir!(), "iso_media_rt_out.bin")
    assert :ok = ISOMedia.write(out, boxes)
    assert File.read!(out) == @bin
  after
    File.rm(Path.join(System.tmp_dir!(), "iso_media_rt.bin"))
    File.rm(Path.join(System.tmp_dir!(), "iso_media_rt_out.bin"))
  end

  describe "lazy read + streaming write" do
    setup do
      ftyp = <<16::32, "ftyp", "isom", 0::32>>
      big = :binary.copy(<<5>>, 4000)
      mdat = <<8 + byte_size(big)::32, "mdat", big::binary>>
      bin = ftyp <> mdat
      src = Path.join(System.tmp_dir!(), "iso_lw_src_#{System.unique_integer([:positive])}.mp4")
      File.write!(src, bin)
      on_exit(fn -> File.rm(src) end)
      {:ok, src: src, bin: bin}
    end

    test "read(lazy: true) keeps mdat as a FileSlice", %{src: src} do
      assert {:ok, boxes} = ISOMedia.read(src, lazy: true, lazy_threshold: 1000)
      mdat = ISOMedia.Box.find(boxes, ~w(mdat))
      assert %ISOMedia.FileSlice{} = mdat.data
    end

    test "write/2 streams a lazy tree byte-identically", %{src: src, bin: bin} do
      {:ok, boxes} = ISOMedia.read(src, lazy: true, lazy_threshold: 1000)
      out = Path.join(System.tmp_dir!(), "iso_lw_out_#{System.unique_integer([:positive])}.mp4")
      on_exit(fn -> File.rm(out) end)
      assert :ok = ISOMedia.write(out, boxes)
      assert File.read!(out) == bin
    end

    test "write/2 refuses to overwrite a FileSlice source", %{src: src} do
      {:ok, boxes} = ISOMedia.read(src, lazy: true, lazy_threshold: 1000)
      assert_raise ArgumentError, ~r/FileSlice source/, fn -> ISOMedia.write(src, boxes) end
    end
  end
end
