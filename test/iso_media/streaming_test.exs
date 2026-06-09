defmodule ISOMedia.StreamingTest do
  use ExUnit.Case
  alias ISOMedia.Streaming

  setup_all do
    {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
    {:ok, frag: ISOMedia.fragment(boxes)}
  end

  test "facade matches the top-level wrappers and impl modules", %{frag: frag} do
    # CMAF
    assert Streaming.split_segments(frag) == ISOMedia.split_segments(frag)
    assert Streaming.split_segments(frag) == ISOMedia.Segment.split(frag)

    # HLS
    assert Streaming.hls_media_playlist(frag) == ISOMedia.hls_media_playlist(frag)
    assert Streaming.hls_media_playlist(frag) == ISOMedia.HLS.media_playlist(frag)
    assert Streaming.hls_master_playlist(frag) == ISOMedia.hls_master_playlist(frag)

    # DASH
    assert Streaming.dash_manifest(frag) == ISOMedia.dash_manifest(frag)
    assert Streaming.dash_manifest(frag) == ISOMedia.DASH.manifest(frag)
  end

  test "byte-range serving matches SeekIndex and serialize/1", %{frag: frag} do
    idx = Streaming.seek_index(frag)
    whole = ISOMedia.serialize(frag)

    assert Streaming.content_length(idx) == byte_size(whole)
    assert Streaming.read_range(idx, 0, byte_size(whole)) == whole
    assert Streaming.read_range(idx, 10, 32) == binary_part(whole, 10, 32)

    streamed = idx |> Streaming.stream_range(10, 32, 8) |> Enum.to_list() |> IO.iodata_to_binary()
    assert streamed == binary_part(whole, 10, 32)
  end
end
