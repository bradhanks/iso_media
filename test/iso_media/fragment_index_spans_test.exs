defmodule ISOMedia.FragmentIndexSpansTest do
  use ExUnit.Case, async: true

  test "fragment_spans returns per-moof duration_ts/timescale/bytes (video-preferred traf)" do
    {:ok, b} = ISOMedia.read("test/fixtures/sample_keyint.mp4")
    f = ISOMedia.fragment(b, target_duration: 0.5)

    assert ISOMedia.FragmentIndex.fragment_spans(f) == [
             %{duration_ts: 10240, timescale: 10240, bytes: 12049},
             %{duration_ts: 10240, timescale: 10240, bytes: 11096}
           ]
  end

  test "fragment_spans count equals the moof count" do
    {:ok, b} = ISOMedia.read("test/fixtures/sample_keyint.mp4")
    f = ISOMedia.fragment(b, target_duration: 0.5)

    assert length(ISOMedia.FragmentIndex.fragment_spans(f)) ==
             Enum.count(f, &(&1.type == "moof"))
  end
end
