defmodule ISOMedia.TrakTest do
  use ExUnit.Case, async: true

  alias ISOMedia.{Box, Trak}

  defp moov do
    {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
    Box.child(boxes, "moov")
  end

  test "id/1 reads a track's tkhd track_id" do
    [trak | _] = Box.children(moov().children, "trak")
    assert Trak.id(trak) == 1
  end

  test "timescale/1 reads a track's media timescale" do
    [trak | _] = Box.children(moov().children, "trak")
    assert Trak.timescale(trak) > 0
  end

  test "movie_timescale/1 reads the mvhd timescale, 1 when absent" do
    m = moov()
    assert Trak.movie_timescale(m) > 0
    assert Trak.movie_timescale(%Box{type: "moov", children: []}) == 1
  end

  test "set_media_duration round-trips through mdhd" do
    [trak | _] = Box.children(moov().children, "trak")
    mdhd = ISOMedia.BoxPath.dig(trak, ~w(mdia mdhd))
    updated = Trak.set_media_duration(mdhd, 12_345)
    assert ISOMedia.Boxes.MediaHeader.decode(updated).duration == 12_345
  end
end
