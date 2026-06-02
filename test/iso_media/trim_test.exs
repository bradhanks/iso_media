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
end
