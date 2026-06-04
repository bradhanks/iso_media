defmodule ISOMedia.Boxes.FragmentEncodeTest do
  use ExUnit.Case
  alias ISOMedia.Boxes.{TrackExtends, TrackFragmentDecodeTime, TrackFragmentHeader, TrackRun}

  test "trex encode/decode round-trips" do
    x = %TrackExtends{
      track_id: 2,
      default_sample_description_index: 1,
      default_sample_duration: 3000,
      default_sample_size: 1024,
      default_sample_flags: 0x01010000
    }

    assert TrackExtends.decode(TrackExtends.encode(x)) == x
  end

  test "tfdt v1 encode/decode round-trips" do
    x = %TrackFragmentDecodeTime{version: 1, base_media_decode_time: 9_000_000_000}
    assert TrackFragmentDecodeTime.decode(TrackFragmentDecodeTime.encode(x)) == x
  end

  test "tfhd (default-base-is-moof, no optionals) round-trips" do
    x = %TrackFragmentHeader{
      track_id: 7,
      base_data_offset: nil,
      sample_description_index: nil,
      default_sample_duration: nil,
      default_sample_size: nil,
      default_sample_flags: nil,
      default_base_is_moof?: true
    }

    assert TrackFragmentHeader.decode(TrackFragmentHeader.encode(x)) == x
  end

  test "trun without composition offsets round-trips (v0)" do
    x = %TrackRun{
      version: 0,
      sample_count: 2,
      data_offset: 158,
      first_sample_flags: nil,
      samples: [
        %{duration: 100, size: 500, flags: 0x00010000, composition_offset: nil},
        %{duration: 100, size: 480, flags: 0x00010000, composition_offset: nil}
      ]
    }

    assert TrackRun.decode(TrackRun.encode(x)) == x
  end

  test "trun with composition offsets round-trips (v1, signed)" do
    x = %TrackRun{
      version: 1,
      sample_count: 2,
      data_offset: 200,
      first_sample_flags: nil,
      samples: [
        %{duration: 90, size: 300, flags: 0x00000000, composition_offset: 0},
        %{duration: 90, size: 310, flags: 0x00000000, composition_offset: -45}
      ]
    }

    assert TrackRun.decode(TrackRun.encode(x)) == x
  end
end
