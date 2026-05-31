defmodule ISOMedia.Boxes.HeadersTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.{MovieHeader, TrackHeader, MediaHeader}

  test "MovieHeader v0 decodes timescale/duration and round-trips" do
    # FullBox(v0) + ctime,mtime,timescale,duration (32 each) + trailing rest
    data = <<0, 0, 0, 0, 100::32, 200::32, 600::32, 1200::32, 0xAA, 0xBB>>
    box = %Box{type: "mvhd", data: data}
    h = MovieHeader.decode(box)
    assert h.timescale == 600
    assert h.duration == 1200
    assert h.creation_time == 100
    assert MovieHeader.encode(h) == box
  end

  test "MovieHeader v1 uses 64-bit times/duration and round-trips" do
    data = <<1, 0, 0, 0, 100::64, 200::64, 600::32, 1200::64, 0xCC>>
    box = %Box{type: "mvhd", data: data}
    h = MovieHeader.decode(box)
    assert h.version == 1
    assert h.timescale == 600
    assert h.duration == 1200
    assert MovieHeader.encode(h) == box
  end

  test "TrackHeader v0 decodes track_id/duration and round-trips" do
    # ctime,mtime,track_ID,reserved,duration + rest
    data = <<0, 0, 0, 7, 100::32, 200::32, 3::32, 0::32, 1200::32, 0xEE>>
    box = %Box{type: "tkhd", data: data}
    h = TrackHeader.decode(box)
    assert h.track_id == 3
    assert h.duration == 1200
    assert h.flags == <<0, 0, 7>>
    assert TrackHeader.encode(h) == box
  end

  test "MediaHeader v0 decodes timescale/duration and round-trips" do
    data = <<0, 0, 0, 0, 100::32, 200::32, 600::32, 1200::32, 0x15, 0xC7, 0, 0>>
    box = %Box{type: "mdhd", data: data}
    h = MediaHeader.decode(box)
    assert h.timescale == 600
    assert h.duration == 1200
    assert MediaHeader.encode(h) == box
  end
end
