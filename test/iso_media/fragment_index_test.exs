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

  describe "samples/2 assembly" do
    defp full_box(type, version, flags_int, payload) do
      %Box{type: type, data: <<version::8, flags_int::24, payload::binary>>}
    end

    defp box_offset(boxes, target) do
      {_, off} =
        Enum.reduce_while(boxes, {0, nil}, fn b, {acc, _} ->
          if b == target,
            do: {:halt, {acc, acc}},
            else: {:cont, {acc + ISOMedia.Layout.box_size(b), nil}}
        end)

      off
    end

    defp tiny_frag_tree do
      trex = full_box("trex", 0, 0, <<1::32, 1::32, 0::32, 0::32, 0::32>>)
      moov = %Box{type: "moov", children: [%Box{type: "mvex", children: [trex]}]}

      # tfhd: default-base-is-moof (0x020000) + default duration (0x8) + default size (0x10)
      tfhd = full_box("tfhd", 0, 0x020018, <<1::32, 100::32, 10::32>>)
      tfdt = full_box("tfdt", 0, 0, <<0::32>>)
      ftyp = %Box{type: "ftyp", data: <<"isom", 0::32>>}
      # mdat holds 20 bytes (2 samples x 10)
      mdat = %Box{type: "mdat", data: <<0::160>>}

      # First pass with placeholder data_offset to learn the tree-local layout.
      placeholder = full_box("trun", 0, 0x000001, <<2::32, 0::signed-32>>)
      traf0 = %Box{type: "traf", children: [tfhd, tfdt, placeholder]}
      moof0 = %Box{type: "moof", children: [traf0]}
      tree0 = [ftyp, moov, moof0, mdat]

      # data_offset such that sample 1 lands exactly on mdat's payload start.
      data_offset = box_offset(tree0, mdat) + 8 - box_offset(tree0, moof0)
      trun = full_box("trun", 0, 0x000001, <<2::32, data_offset::signed-32>>)
      traf = %Box{type: "traf", children: [tfhd, tfdt, trun]}
      moof = %Box{type: "moof", children: [traf]}
      [ftyp, moov, moof, mdat]
    end

    test "computes offsets, dts/pts, sizes, and per-trun chunk_index" do
      samples = FragmentIndex.samples(tiny_frag_tree(), 1)
      assert length(samples) == 2
      [s1, s2] = samples
      assert s1.index == 1 and s2.index == 2
      assert s1.chunk_index == 1 and s2.chunk_index == 1
      assert s1.size == 10 and s2.size == 10
      assert s1.duration == 100
      assert s1.dts == 0 and s2.dts == 100
      assert s1.pts == 0 and s2.pts == 100
      assert s2.offset == s1.offset + 10
    end

    test "raises when a fragment does not use default-base-is-moof" do
      tfhd = full_box("tfhd", 0, 0x000008, <<1::32, 100::32>>)
      trun = full_box("trun", 0, 0x000001, <<1::32, 0::signed-32>>)
      traf = %Box{type: "traf", children: [tfhd, trun]}
      moof = %Box{type: "moof", children: [traf]}
      trex = full_box("trex", 0, 0, <<1::32, 1::32, 0::32, 0::32, 0::32>>)
      moov = %Box{type: "moov", children: [%Box{type: "mvex", children: [trex]}]}
      tree = [%Box{type: "ftyp", data: <<0::32>>}, moov, moof, %Box{type: "mdat", data: <<0::80>>}]

      assert_raise ArgumentError, ~r/default-base-is-moof/, fn ->
        FragmentIndex.samples(tree, 1)
      end
    end
  end
end
