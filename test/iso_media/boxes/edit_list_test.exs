defmodule ISOMedia.Boxes.EditListTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.EditList

  test "decodes a v0 elst" do
    # version 0, 1 entry: segment_duration 25, media_time 5, rate 1.0
    data = <<0, 0, 0, 0, 1::32, 25::32, 5::signed-32, 1::signed-16, 0::16>>
    el = EditList.decode(%Box{type: "elst", data: data})
    assert el.version == 0

    assert el.entries == [
             %{segment_duration: 25, media_time: 5, rate_integer: 1, rate_fraction: 0}
           ]
  end

  test "decodes a v0 empty edit (media_time -1)" do
    data = <<0, 0, 0, 0, 1::32, 100::32, -1::signed-32, 1::signed-16, 0::16>>
    el = EditList.decode(%Box{type: "elst", data: data})
    assert hd(el.entries).media_time == -1
  end

  test "v0 round-trips (small values stay v0)" do
    box = %Box{
      type: "elst",
      data: <<0, 0, 0, 0, 1::32, 25::32, 5::signed-32, 1::signed-16, 0::16>>
    }

    assert EditList.encode(EditList.decode(box)) == box
  end

  test "encode upgrades to v1 when a value exceeds 32 bits" do
    el = %EditList{
      version: 0,
      entries: [
        %{segment_duration: 5_000_000_000, media_time: 0, rate_integer: 1, rate_fraction: 0}
      ]
    }

    box = EditList.encode(el)
    assert <<1::8, 0::24, 1::32, 5_000_000_000::64, 0::signed-64, 1::signed-16, 0::16>> = box.data
    # and it round-trips back to the same struct (now v1)
    assert EditList.decode(box).entries == el.entries
  end
end
