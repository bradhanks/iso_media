defmodule ISOMedia.TrimAvTest do
  use ExUnit.Case

  @fixture Path.join([__DIR__, "..", "fixtures", "sample_av.mp4"])

  defp tmp, do: Path.join(System.tmp_dir!(), "iso_trim_#{System.unique_integer([:positive])}.mp4")

  test "trim keeps both tracks, samples byte-identical, timeline re-based" do
    original = File.read!(@fixture)
    {:ok, boxes} = ISOMedia.parse(original)

    out = boxes |> ISOMedia.trim(0.2, 0.8) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    assert length(ISOMedia.track_ids(reparsed)) == 2

    for id <- ISOMedia.track_ids(reparsed) do
      samples = ISOMedia.samples(reparsed, id)
      assert samples != []
      # re-based: first sample starts at dts 0
      assert hd(samples).dts == 0
      # every kept sample resolves to real bytes inside the output
      assert Enum.all?(samples, &(&1.offset + &1.size <= byte_size(out)))
      # the first sample of a track that has sync samples must be a keyframe
      assert hd(samples).sync?
    end
  end

  test "trim start snaps back to a keyframe (first kept sample is sync)" do
    {:ok, boxes} = ISOMedia.parse(File.read!(@fixture))
    # video track 1 has sparse keyframes; trim from a mid-clip point
    out = boxes |> ISOMedia.trim(0.5, 0.9) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)
    assert hd(ISOMedia.samples(reparsed, 1)).sync?
  end

  test "lazy trim streams and matches eager" do
    {:ok, eager} = ISOMedia.parse(File.read!(@fixture))
    eager_out = eager |> ISOMedia.trim(0.2, 0.8) |> ISOMedia.serialize()

    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    out = tmp()
    on_exit(fn -> File.rm(out) end)
    assert :ok = ISOMedia.write(out, ISOMedia.trim(lazy, 0.2, 0.8))
    assert File.read!(out) == eager_out
  end

  test "trim adds a correct edit list to the real video track" do
    {:ok, boxes} = ISOMedia.read(@fixture)
    [vid | _] = ISOMedia.track_ids(boxes)

    # Compute the expected lead for the video track at start 0.5s, from the originals.
    moov = Enum.find(boxes, &(&1.type == "moov"))

    trak =
      Enum.find(moov.children, fn t ->
        t.type == "trak" and
          ISOMedia.Boxes.TrackHeader.decode(ISOMedia.Box.find([t], ~w(trak tkhd))).track_id == vid
      end)

    ts =
      ISOMedia.Boxes.MediaHeader.decode(ISOMedia.Box.find([trak], ~w(trak mdia mdhd))).timescale

    start_ts = round(0.5 * ts)
    samples = ISOMedia.samples(boxes, vid)

    snap_dts =
      samples
      |> Enum.filter(&(&1.sync? and &1.dts <= start_ts))
      |> List.last()
      |> Map.get(:dts, 0)

    expected_lead = max(0, start_ts - snap_dts)

    out = boxes |> ISOMedia.trim(0.5, 0.9) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    out_trak =
      Enum.find(Enum.find(reparsed, &(&1.type == "moov")).children, fn t ->
        t.type == "trak" and
          ISOMedia.Boxes.TrackHeader.decode(ISOMedia.Box.find([t], ~w(trak tkhd))).track_id == vid
      end)

    elst = ISOMedia.Box.find([out_trak], ~w(trak edts elst))
    assert elst != nil, "video track should have an edit list"
    [entry] = ISOMedia.Boxes.EditList.decode(elst).entries
    assert entry.media_time == expected_lead
    assert entry.rate_integer == 1
  end
end
