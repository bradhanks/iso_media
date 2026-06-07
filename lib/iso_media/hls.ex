defmodule ISOMedia.HLS do
  @moduledoc """
  Generate HLS (`.m3u8`) playlists for the CMAF segments `ISOMedia.split_segments/1`
  produces — a media playlist (segment list) and a multivariant (master) playlist
  (codecs/resolution/bandwidth), for a single muxed VOD rendition. Pure string templating
  over `FragmentIndex.fragment_spans/1` + `ISOMedia.track_info/2`; URIs match `write_segments`.
  """
  alias ISOMedia.FragmentIndex

  @doc "The HLS media playlist (`.m3u8`) for a fragmented tree."
  @spec media_playlist([ISOMedia.Box.t()], keyword()) :: String.t()
  def media_playlist(boxes, opts \\ []) do
    validate!(boxes)
    init_name = Keyword.get(opts, :init_name, "init.mp4")
    pattern = Keyword.get(opts, :segment_pattern, fn i -> "seg-#{i}.m4s" end)
    spans = FragmentIndex.fragment_spans(boxes)
    target = spans |> Enum.map(&seconds/1) |> Enum.max() |> Float.ceil() |> trunc()

    segment_lines =
      spans
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {s, i} ->
        ["#EXTINF:#{:erlang.float_to_binary(seconds(s), decimals: 3)},", pattern.(i)]
      end)

    lines =
      [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        "#EXT-X-PLAYLIST-TYPE:VOD",
        "#EXT-X-TARGETDURATION:#{target}",
        ~s(#EXT-X-MAP:URI="#{init_name}")
      ] ++ segment_lines ++ ["#EXT-X-ENDLIST"]

    Enum.join(lines, "\n") <> "\n"
  end

  defp seconds(%{duration_ts: d, timescale: ts}), do: d / ts

  defp validate!(boxes) do
    unless FragmentIndex.fragmented?(boxes) do
      raise ArgumentError, "hls: expected a fragmented (fragment/2) tree"
    end
  end
end
