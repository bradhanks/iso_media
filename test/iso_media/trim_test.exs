defmodule ISOMedia.TrimTest do
  use ExUnit.Case

  # Two tracks, each 4 samples in two chunks of 2, duration 100 each (timescale via mdhd).
  # MP4Builder doesn't emit mdhd, so trim falls back to timescale 1 (durations are the units).
  defp build do
    specs = [
      %{
        id: 1,
        chunks: [[<<1, 1>>, <<2, 2>>], [<<3, 3>>, <<4, 4>>]],
        durations: [10, 10, 10, 10],
        sync: [1, 3]
      },
      %{id: 2, chunks: [[<<5>>, <<6>>], [<<7>>, <<8>>]], durations: [10, 10, 10, 10]}
    ]

    %{binary: bin} = ISOMedia.Support.MP4Builder.build_tracks(specs)
    {:ok, boxes} = ISOMedia.parse(bin)
    {bin, boxes}
  end

  test "trim keeps samples in range and re-bases the timeline to 0" do
    {_bin, boxes} = build()
    # timescale defaults to 1 (no mdhd), so seconds == duration units. Keep dts in [10, 30).
    out = boxes |> ISOMedia.trim(10, 30) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    s1 = ISOMedia.samples(reparsed, 1)
    # track 1 sync samples at dts 0 and 20; start 10 snaps back to keyframe at dts 0 (sample 1).
    # kept: samples with dts in [0(snap)..<30] = samples 1,2,3 (dts 0,10,20).
    assert Enum.map(s1, & &1.dts) == [0, 10, 20]
    assert Enum.map(s1, &binary_part(out, &1.offset, &1.size)) == [<<1, 1>>, <<2, 2>>, <<3, 3>>]
    # re-based: first dts is 0
    assert hd(s1).dts == 0
  end

  # The sequence of track ids when every track's chunk offsets are merged and sorted by
  # offset. For a round-robin-interleaved file this alternates (e.g. [1, 2, 1, 2]); if the
  # writer collapsed to block-per-track it would group (e.g. [1, 1, 2, 2]).
  defp interleave_sequence(boxes) do
    moov = Enum.find(boxes, &(&1.type == "moov"))

    for trak <- Enum.filter(moov.children, &(&1.type == "trak")),
        id = ISOMedia.Boxes.TrackHeader.decode(ISOMedia.Box.find([trak], ~w(trak tkhd))).track_id,
        stco = ISOMedia.Box.find([trak], ~w(trak mdia minf stbl stco)),
        off <- ISOMedia.Boxes.ChunkOffset.decode(stco).offsets do
      {off, id}
    end
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  test "trim preserves A/V interleave (output chunk order matches the original)" do
    {bin, boxes} = build()
    {:ok, orig} = ISOMedia.parse(bin)
    out = boxes |> ISOMedia.trim(0, 40) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    # The original is round-robin interleaved ([1, 2, 1, 2]); keeping everything must
    # preserve that order, NOT collapse to block-per-track ([1, 1, 2, 2]).
    assert interleave_sequence(orig) == [1, 2, 1, 2]
    assert interleave_sequence(reparsed) == interleave_sequence(orig)
  end

  test "every kept sample's bytes are byte-identical to the original" do
    {bin, boxes} = build()
    out = boxes |> ISOMedia.trim(0, 40) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)
    {:ok, orig} = ISOMedia.parse(bin)

    for id <- ISOMedia.track_ids(reparsed) do
      orig_bytes = ISOMedia.samples(orig, id) |> Enum.map(&binary_part(bin, &1.offset, &1.size))

      new_bytes =
        ISOMedia.samples(reparsed, id) |> Enum.map(&binary_part(out, &1.offset, &1.size))

      assert new_bytes == orig_bytes
    end
  end

  test "raises when end <= start" do
    {_bin, boxes} = build()
    assert_raise ArgumentError, fn -> ISOMedia.trim(boxes, 30, 10) end
  end

  test "raises when the range is past the content (no samples in the window)" do
    {_bin, boxes} = build()
    # content ends at dts 30; a window at 10_000 contains no sample
    assert_raise ArgumentError, ~r/selects no samples/, fn ->
      ISOMedia.trim(boxes, 10_000, 10_001)
    end
  end

  test "start snaps back to the NEAREST preceding keyframe (not the first, not forward)" do
    # 5 samples, dts 0/10/20/30/40, distinct bytes; sparse keyframes at samples 1 and 3.
    specs = [
      %{
        id: 1,
        chunks: [[<<1>>, <<2>>, <<3>>, <<4>>, <<5>>]],
        durations: [10, 10, 10, 10, 10],
        sync: [1, 3]
      }
    ]

    %{binary: bin} = ISOMedia.Support.MP4Builder.build_tracks(specs)
    {:ok, boxes} = ISOMedia.parse(bin)

    # Window [35, 100) contains only sample 5 (dts 40). The nearest preceding keyframe is
    # sample 3 (dts 20) — NOT sample 1 (first keyframe) and NOT sample 5 (no snap).
    out = boxes |> ISOMedia.trim(35, 100) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    s = ISOMedia.samples(reparsed, 1)

    # kept = samples 3, 4, 5 -> bytes <<3>>,<<4>>,<<5>>; first is the snap keyframe, re-based to 0.
    assert Enum.map(s, &binary_part(out, &1.offset, &1.size)) == [<<3>>, <<4>>, <<5>>]
    assert hd(s).dts == 0
    assert hd(s).sync?
  end

  test "trim adds a frame-accurate edit list (media_time = snap lead)" do
    # track 1 keyframes at samples 1 & 3 (dts 0 & 20), durations 10 → dts 0,10,20,30.
    {_bin, boxes} = build()
    # start 25 snaps back to keyframe sample 3 (dts 20): lead = 25 - 20 = 5.
    out = boxes |> ISOMedia.trim(25, 35) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    elst = ISOMedia.Box.find(reparsed, ~w(moov trak edts elst))
    el = ISOMedia.Boxes.EditList.decode(elst)
    # kept = samples 3,4 (durations 10 each) → visible = 20 - 5 = 15; timescales = 1.
    assert el.entries == [
             %{segment_duration: 15, media_time: 5, rate_integer: 1, rate_fraction: 0}
           ]

    # samples are unchanged by the edit list
    s = ISOMedia.samples(reparsed, 1)
    assert Enum.map(s, &binary_part(out, &1.offset, &1.size)) == [<<3, 3>>, <<4, 4>>]
  end

  test "trim emits no edts when the start lands exactly on a keyframe" do
    {_bin, boxes} = build()
    # start 20 == keyframe sample 3's dts → lead 0 → no edit list.
    out = boxes |> ISOMedia.trim(20, 35) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)
    assert ISOMedia.Box.find(reparsed, ~w(moov trak edts)) == nil
  end

  # A single-track clip with two chunks (1 sample each) physically out of logical
  # order (sample 2's bytes precede sample 1's) → non-monotonic stco. Exercises the
  # physical-vs-logical stco/stsc alignment that MP4Builder can't (it emits monotonic).
  defp nonmono_clip(s1, s2) do
    leaf = fn type, data -> <<8 + byte_size(data)::32, type::binary, data::binary>> end
    container = fn type, inner -> <<8 + byte_size(inner)::32, type::binary, inner::binary>> end

    stsd = leaf.("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf.("stts", <<0, 0, 0, 0, 1::32, 2::32, 10::32>>)
    stsc = leaf.("stsc", <<0, 0, 0, 0, 1::32, 1::32, 1::32, 1::32>>)
    stsz = leaf.("stsz", <<0, 0, 0, 0, 0::32, 2::32, byte_size(s1)::32, byte_size(s2)::32>>)
    mdhd = leaf.("mdhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::16, 0::16>>)
    tkhd = leaf.("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::32>>)
    ftyp = leaf.("ftyp", <<"isom", 0::32, "isom">>)

    moov_with = fn off1, off2 ->
      stco = leaf.("stco", <<0, 0, 0, 0, 2::32, off1::32, off2::32>>)
      stbl = container.("stbl", stsd <> stts <> stsc <> stsz <> stco)

      container.(
        "moov",
        container.("trak", tkhd <> container.("mdia", mdhd <> container.("minf", stbl)))
      )
    end

    payload_start = byte_size(ftyp) + byte_size(moov_with.(0, 0)) + 8
    off2 = payload_start
    off1 = payload_start + byte_size(s2)
    {:ok, boxes} = ISOMedia.parse(ftyp <> moov_with.(off1, off2) <> leaf.("mdat", s2 <> s1))
    boxes
  end

  test "trim keeps logical sample order when source chunks are physically out of order" do
    boxes = nonmono_clip(<<1>>, <<2>>)
    # keep everything (dts 0 and 10, durations 10) — both samples survive.
    out = boxes |> ISOMedia.trim(0, 1000) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    s = ISOMedia.samples(reparsed, 1)
    assert Enum.map(s, &binary_part(out, &1.offset, &1.size)) == [<<1>>, <<2>>]
  end
end
