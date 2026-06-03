defmodule ISOMedia.Boxes.FragmentBoxesTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.{TrackExtends, TrackFragmentDecodeTime, TrackFragmentHeader, TrackRun}

  test "trex decodes the five default fields" do
    data = <<0, 0, 0, 0, 1::32, 1::32, 3000::32, 1024::32, 0x01010000::32>>
    t = TrackExtends.decode(%Box{type: "trex", data: data})
    assert t.track_id == 1
    assert t.default_sample_description_index == 1
    assert t.default_sample_duration == 3000
    assert t.default_sample_size == 1024
    assert t.default_sample_flags == 0x01010000
  end

  test "tfdt v0 and v1 decode base_media_decode_time" do
    v0 = TrackFragmentDecodeTime.decode(%Box{type: "tfdt", data: <<0, 0, 0, 0, 5120::32>>})
    assert v0.version == 0 and v0.base_media_decode_time == 5120

    v1 =
      TrackFragmentDecodeTime.decode(%Box{type: "tfdt", data: <<1, 0, 0, 0, 9_000_000_000::64>>})

    assert v1.version == 1 and v1.base_media_decode_time == 9_000_000_000
  end

  test "tfhd parses only the flag-gated fields and default_base_is_moof" do
    # flags 0x020008: default-base-is-moof + default-sample-duration-present
    data = <<0, 0x02, 0x00, 0x08, 7::32, 3000::32>>
    h = TrackFragmentHeader.decode(%Box{type: "tfhd", data: data})
    assert h.track_id == 7
    assert h.default_base_is_moof? == true
    assert h.default_sample_duration == 3000
    assert h.default_sample_size == nil
    assert h.base_data_offset == nil
  end

  test "trun parses data_offset, first_sample_flags and per-sample fields" do
    # flags 0x000301 = data-offset-present(0x1) | sample-duration(0x100) | sample-size(0x200)
    data = <<0, 0x00, 0x03, 0x01, 2::32, 158::signed-32, 100::32, 500::32, 90::32, 480::32>>
    t = TrackRun.decode(%Box{type: "trun", data: data})
    assert t.sample_count == 2
    assert t.data_offset == 158
    assert t.first_sample_flags == nil

    assert t.samples == [
             %{duration: 100, size: 500, flags: nil, composition_offset: nil},
             %{duration: 90, size: 480, flags: nil, composition_offset: nil}
           ]
  end

  test "trun v1 composition offsets are signed" do
    # flags 0x000800 = sample-composition-time-offsets-present, version 1
    data = <<1, 0x00, 0x08, 0x00, 1::32, -50::signed-32>>
    t = TrackRun.decode(%Box{type: "trun", data: data})
    assert t.samples == [%{duration: nil, size: nil, flags: nil, composition_offset: -50}]
  end
end
