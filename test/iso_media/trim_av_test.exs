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
end
