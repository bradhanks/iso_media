defmodule ISOMedia.ExtractAvTest do
  use ExUnit.Case

  @fixture Path.join([__DIR__, "..", "fixtures", "sample_av.mp4"])

  test "the fixture has two tracks" do
    {:ok, boxes} = ISOMedia.read(@fixture)
    assert length(ISOMedia.track_ids(boxes)) == 2
  end

  test "extracting a track yields a one-track file whose samples match the originals" do
    original = File.read!(@fixture)
    {:ok, boxes} = ISOMedia.read(@fixture)
    [tid | _] = ISOMedia.track_ids(boxes)

    original_samples = ISOMedia.samples(boxes, tid)

    out_boxes = ISOMedia.extract_track(boxes, tid)
    out = ISOMedia.serialize(out_boxes)
    {:ok, reparsed} = ISOMedia.parse(out)

    assert ISOMedia.track_ids(reparsed) == [tid]
    extracted = ISOMedia.samples(reparsed, tid)
    assert length(extracted) == length(original_samples)

    # Each extracted sample's bytes equal the original sample's bytes.
    Enum.zip(original_samples, extracted)
    |> Enum.each(fn {o, e} ->
      assert e.size == o.size
      assert binary_part(out, e.offset, e.size) == binary_part(original, o.offset, o.size)
    end)
  end

  test "lazy extraction streams the kept track and matches eager" do
    {:ok, eager} = ISOMedia.read(@fixture)
    [tid | _] = ISOMedia.track_ids(eager)
    eager_out = eager |> ISOMedia.extract_track(tid) |> ISOMedia.serialize()

    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    out = Path.join(System.tmp_dir!(), "iso_av_#{System.unique_integer([:positive])}.mp4")
    on_exit(fn -> File.rm(out) end)
    assert :ok = ISOMedia.write(out, ISOMedia.extract_track(lazy, tid))
    assert File.read!(out) == eager_out
  end
end
