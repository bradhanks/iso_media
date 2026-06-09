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

    test "the first window keeps samples before the first boundary (lossless)" do
      # leading non-sync samples (dts 0, 10) before the first keyframe at dts 20
      samples = [s(0, false), s(10, false), s(20, true), s(30, false), s(40, true)]
      windows = Fragment.windows(samples, [20, 40])
      # nothing dropped; the leading samples land in the first window
      assert windows |> List.flatten() |> length() == 5

      assert Enum.map(windows, fn run -> Enum.map(run, & &1.dts) end) == [[0, 10, 20, 30], [40]]
    end

    test "empty boundaries yields no windows" do
      assert Fragment.windows([s(0, true), s(10, true)], []) == []
    end

    test "a sample whose dts equals a boundary belongs to the later window [b_i, b_{i+1})" do
      samples = for d <- 0..50//10, do: s(d, true)
      windows = Fragment.windows(samples, [0, 20, 40])

      assert Enum.map(windows, fn run -> Enum.map(run, & &1.dts) end) ==
               [[0, 10], [20, 30], [40, 50]]
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

  describe "round trip (the proof)" do
    @keyint "test/fixtures/sample_keyint.mp4"

    defp sample_bytes(boxes, samples) do
      recs = ISOMedia.MdatSource.collect(boxes)

      samples
      |> Enum.map(fn smp ->
        seg = ISOMedia.MdatSource.segment(recs, smp.offset, smp.size)
        ISOMedia.Box.read_data(%ISOMedia.Box{type: "x", data: List.wrap(seg)})
      end)
      |> IO.iodata_to_binary()
    end

    test "the keyint fixture yields >= 2 fragments and every fragment starts on a keyframe" do
      {:ok, boxes} = ISOMedia.read(@keyint)
      out = ISOMedia.fragment(boxes, target_duration: 0.3)
      assert Enum.count(out, &(&1.type == "moof")) >= 2

      [vid | _] =
        Enum.filter(ISOMedia.track_ids(boxes), fn tid ->
          s = ISOMedia.samples(boxes, tid)
          Enum.count(s, & &1.sync?) < length(s)
        end)

      frag = ISOMedia.samples(out, vid)
      firsts = frag |> Enum.group_by(& &1.chunk_index) |> Map.values() |> Enum.map(&hd/1)
      assert Enum.all?(firsts, & &1.sync?)
    end

    test "defragment(fragment(x)) reproduces per-sample timing and bytes" do
      {:ok, boxes} = ISOMedia.read(@keyint)
      round = boxes |> ISOMedia.fragment(target_duration: 0.3) |> ISOMedia.defragment()

      for tid <- ISOMedia.track_ids(boxes) do
        orig = ISOMedia.samples(boxes, tid)
        rt = ISOMedia.samples(round, tid)
        assert Enum.map(rt, & &1.dts) == Enum.map(orig, & &1.dts)
        assert Enum.map(rt, & &1.pts) == Enum.map(orig, & &1.pts)
        assert Enum.map(rt, & &1.size) == Enum.map(orig, & &1.size)
        assert Enum.map(rt, & &1.sync?) == Enum.map(orig, & &1.sync?)
        assert sample_bytes(round, rt) == sample_bytes(boxes, orig)
      end
    end

    test "audio-only fragments and round-trips" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample.m4a")
      out = ISOMedia.fragment(boxes, target_duration: 0.3)
      assert ISOMedia.FragmentIndex.fragmented?(out)
      round = ISOMedia.defragment(out)
      [tid] = ISOMedia.track_ids(boxes)

      assert Enum.map(ISOMedia.samples(round, tid), & &1.size) ==
               Enum.map(ISOMedia.samples(boxes, tid), & &1.size)
    end

    test "lazy and eager fragmenting produce identical bytes" do
      {:ok, eager} = ISOMedia.read(@keyint)
      {:ok, lazy} = ISOMedia.read(@keyint, lazy: true)

      assert ISOMedia.serialize(ISOMedia.fragment(eager)) ==
               ISOMedia.serialize(ISOMedia.fragment(lazy))
    end

    test "fragmenting a trimmed input strips edts from the init moov" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
      trimmed = ISOMedia.trim(boxes, 0.2, 0.8)
      out = ISOMedia.fragment(trimmed, target_duration: 0.3)
      moov = Enum.find(out, &(&1.type == "moov"))

      for trak <- Enum.filter(moov.children, &(&1.type == "trak")) do
        refute Enum.any?(trak.children, &(&1.type == "edts"))
      end
    end

    test "trailing sidx/mfra are opaque leaves and ignored by indexing" do
      {:ok, boxes} = ISOMedia.read(@keyint)
      out = ISOMedia.fragment(boxes, target_duration: 0.3)

      with_trailers =
        out ++
          [
            %ISOMedia.Box{type: "sidx", data: <<0::96>>},
            %ISOMedia.Box{type: "mfra", data: <<0::64>>}
          ]

      assert [%ISOMedia.Box{type: "sidx", data: d}] =
               Enum.filter(with_trailers, &(&1.type == "sidx"))

      assert is_binary(d)
      [tid | _] = ISOMedia.track_ids(with_trailers)
      assert is_list(ISOMedia.samples(with_trailers, tid))
    end
  end
end
