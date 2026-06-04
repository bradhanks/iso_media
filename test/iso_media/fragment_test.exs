defmodule ISOMedia.FragmentTest do
  use ExUnit.Case
  alias ISOMedia.{Fragment, Sample}

  defp s(dts, sync?),
    do: %Sample{
      index: 0,
      chunk_index: 1,
      dts: dts,
      duration: 10,
      pts: dts,
      size: 5,
      offset: 0,
      sync?: sync?
    }

  describe "boundaries/2" do
    test "sparse keyframes: a boundary at the first sync >= last + target" do
      # keyframes at dts 0, 30, 60, 90; others non-sync
      samples =
        for d <- 0..90//10 do
          s(d, rem(d, 30) == 0)
        end

      # target 25: boundaries at 0, 30, 60, 90 (each next keyframe past +25)
      assert Fragment.boundaries(samples, 25) == [0, 30, 60, 90]
      # target 35: skip the keyframe at 30 (0+35=35 > 30), take 60, then 90
      assert Fragment.boundaries(samples, 35) == [0, 60]
    end

    test "all-sync (audio): boundaries purely by duration" do
      samples = for d <- 0..90//10, do: s(d, true)
      assert Fragment.boundaries(samples, 30) == [0, 30, 60, 90]
    end
  end

  describe "windows/2" do
    test "partitions samples into [b_i, b_{i+1}) by dts" do
      samples = for d <- 0..90//10, do: s(d, true)
      # boundaries 0, 40, 80 -> windows [0..30], [40..70], [80..90]
      windows = Fragment.windows(samples, [0, 40, 80])

      assert Enum.map(windows, fn run -> Enum.map(run, & &1.dts) end) ==
               [[0, 10, 20, 30], [40, 50, 60, 70], [80, 90]]
    end

    test "a track with no samples in a window yields an empty run there" do
      samples = [s(0, true), s(50, true)]
      windows = Fragment.windows(samples, [0, 20, 40])
      assert Enum.map(windows, &length/1) == [1, 0, 1]
    end
  end

  describe "fragment/2 structure" do
    test "produces a valid multiplexed fMP4 tree from a progressive file" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
      out = ISOMedia.fragment(boxes, target_duration: 0.3)

      assert hd(out).type == "ftyp"
      assert Enum.at(out, 1).type == "moov"
      assert ISOMedia.FragmentIndex.fragmented?(out)

      moov = Enum.find(out, &(&1.type == "moov"))
      assert Enum.any?(moov.children, &(&1.type == "mvex"))
      # init trak stbl carries stsd but zero samples
      trak = Enum.find(moov.children, &(&1.type == "trak"))
      stbl = ISOMedia.BoxPath.dig(trak, ~w(mdia minf stbl))
      assert Enum.any?(stbl.children, &(&1.type == "stsd"))
      refute Enum.any?(trak.children, &(&1.type == "edts"))

      # the output re-serializes and re-parses cleanly
      assert {:ok, _} = ISOMedia.parse(ISOMedia.serialize(out))
    end
  end

  describe "build_fragment/4 (data_offset invariant)" do
    test "trun data_offset points exactly into the sibling mdat payload" do
      # one track, 2 samples of 10 bytes each, sourced from an in-memory mdat
      payload = for(i <- 0..19, into: <<>>, do: <<i>>)
      src_mdat = %ISOMedia.Box{type: "mdat", size_mode: :compact, data: payload}
      mdats = ISOMedia.MdatSource.collect([src_mdat])

      run = [
        %Sample{
          index: 1,
          chunk_index: 1,
          dts: 0,
          duration: 5,
          pts: 0,
          size: 10,
          offset: 8,
          sync?: true
        },
        %Sample{
          index: 2,
          chunk_index: 1,
          dts: 5,
          duration: 5,
          pts: 5,
          size: 10,
          offset: 18,
          sync?: true
        }
      ]

      metas = [%{track_id: 1, timescale: 1000, handler: "vide", samples: run, trak: nil}]
      {moof, mdat} = Fragment.build_fragment(1, [run], metas, mdats)

      trex =
        ISOMedia.Boxes.TrackExtends.encode(%ISOMedia.Boxes.TrackExtends{
          track_id: 1,
          default_sample_description_index: 1,
          default_sample_duration: 0,
          default_sample_size: 0,
          default_sample_flags: 0
        })

      # the moof+mdat must be a self-consistent fragment: parse it back via FragmentIndex.
      tree = [
        %ISOMedia.Box{type: "ftyp", data: <<"isom", 0::32>>},
        %ISOMedia.Box{type: "moov", children: [%ISOMedia.Box{type: "mvex", children: [trex]}]},
        moof,
        mdat
      ]

      samples = ISOMedia.FragmentIndex.samples(tree, 1)
      assert Enum.map(samples, & &1.size) == [10, 10]
      assert Enum.map(samples, & &1.dts) == [0, 5]
      # resolved bytes equal the original payload bytes for each sample
      recs = ISOMedia.MdatSource.collect(tree)

      bytes =
        Enum.map(samples, fn smp ->
          seg = ISOMedia.MdatSource.segment(recs, smp.offset, smp.size)
          ISOMedia.Box.read_data(%ISOMedia.Box{type: "x", data: List.wrap(seg)})
        end)

      assert IO.iodata_to_binary(bytes) == payload
    end
  end
end
