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
end
