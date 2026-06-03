defmodule ISOMedia.FragmentIndexTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FragmentIndex}

  defp moov(children), do: %Box{type: "moov", children: children}
  defp leaf(type, data), do: %Box{type: type, data: data}

  test "fragmented?/1 is true only with both mvex and moof" do
    mvex = %Box{type: "mvex", children: [leaf("trex", <<0::32, 1::32, 1::32, 0::32, 0::32, 0::32>>)]}
    moof = %Box{type: "moof", children: []}

    assert FragmentIndex.fragmented?([moov([mvex]), moof]) == true
    assert FragmentIndex.fragmented?([moov([mvex])]) == false
    assert FragmentIndex.fragmented?([moov([]), moof]) == false
    assert FragmentIndex.fragmented?([moov([])]) == false
  end

  test "samples/2 still routes a progressive file to SampleTable" do
    {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
    [tid | _] = ISOMedia.track_ids(boxes)
    assert is_list(ISOMedia.samples(boxes, tid))
    assert FragmentIndex.fragmented?(boxes) == false
  end

  alias ISOMedia.Boxes.TrackRun

  describe "resolve_run/2 cascade" do
    test "uses trun entry values when present" do
      trun = %TrackRun{
        version: 0,
        sample_count: 1,
        data_offset: 0,
        first_sample_flags: nil,
        samples: [%{duration: 50, size: 10, flags: 0x00000000, composition_offset: 7}]
      }

      assert FragmentIndex.resolve_run(trun, %{duration: 999, size: 999, flags: 0x00010000}) ==
               [%{duration: 50, size: 10, composition_offset: 7, sync?: true}]
    end

    test "falls back to defaults (tfhd-over-trex merged) when trun omits fields" do
      trun = %TrackRun{
        version: 0,
        sample_count: 1,
        data_offset: 0,
        first_sample_flags: nil,
        samples: [%{duration: nil, size: nil, flags: nil, composition_offset: nil}]
      }

      # default flags mark non-sync (bit 0x00010000 set) -> sync? false
      assert FragmentIndex.resolve_run(trun, %{duration: 3000, size: 1024, flags: 0x00010000}) ==
               [%{duration: 3000, size: 1024, composition_offset: 0, sync?: false}]
    end

    test "first_sample_flags applies to sample 1 only" do
      trun = %TrackRun{
        version: 0,
        sample_count: 2,
        data_offset: 0,
        first_sample_flags: 0x02000000,
        samples: [
          %{duration: 30, size: 5, flags: nil, composition_offset: nil},
          %{duration: 30, size: 5, flags: 0x00010000, composition_offset: nil}
        ]
      }

      assert [%{sync?: true}, %{sync?: false}] =
               FragmentIndex.resolve_run(trun, %{duration: nil, size: nil, flags: 0x00010000})
    end
  end
end
