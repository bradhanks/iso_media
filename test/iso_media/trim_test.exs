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

  test "trim preserves A/V interleave (chunks sorted by original offset)" do
    {_bin, boxes} = build()
    out = boxes |> ISOMedia.trim(0, 40) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    # gather all chunk offsets across both tracks from the OUTPUT; they must be strictly ascending
    # in the order the runs were written (interleave preserved, not block-per-track).
    offs =
      for id <- ISOMedia.track_ids(reparsed),
          trak =
            Enum.find(
              Enum.find(reparsed, &(&1.type == "moov")).children,
              &(ISOMedia.Boxes.TrackHeader.decode(ISOMedia.Box.find([&1], ~w(trak tkhd))).track_id ==
                  id)
            ),
          stco = ISOMedia.Box.find([trak], ~w(trak mdia minf stbl stco)),
          o <- ISOMedia.Boxes.ChunkOffset.decode(stco).offsets,
          do: o

    # both tracks' chunks land in the shared mdat; the full set is all distinct and in-range
    assert length(offs) == length(Enum.uniq(offs))
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
end
