defmodule ISOMedia.HLS do
  @moduledoc """
  Generate HLS (`.m3u8`) playlists for the CMAF segments `ISOMedia.split_segments/1`
  produces — a media playlist (segment list) and a multivariant (master) playlist
  (codecs/resolution/bandwidth), for a single muxed VOD rendition. Pure string templating
  over `FragmentIndex.fragment_spans/1` + `ISOMedia.Manifest`; URIs match `write_segments`.
  """
  alias ISOMedia.{FragmentIndex, Manifest}

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

  @doc "The HLS multivariant (master) playlist (`.m3u8`) for a fragmented tree."
  @spec master_playlist([ISOMedia.Box.t()], keyword()) :: String.t()
  def master_playlist(boxes, opts \\ []) do
    validate!(boxes)
    media_uri = Keyword.get(opts, :media_uri, "media.m3u8")

    attrs =
      ["BANDWIDTH=#{Manifest.peak_bandwidth(boxes)}", ~s(CODECS="#{Manifest.codecs(boxes)}")] ++
        case Manifest.resolution(boxes) do
          nil -> []
          res -> ["RESOLUTION=#{res}"]
        end

    Enum.join(["#EXTM3U", "#EXT-X-STREAM-INF:#{Enum.join(attrs, ",")}", media_uri], "\n") <> "\n"
  end

  @doc """
  Write the HLS bundle into `dir` (created if absent): `master.m3u8`, the media playlist
  (`opts[:media_uri]`, default `media.m3u8`), and — via `ISOMedia.write_segments/3` — `init.mp4`
  + `seg-N.m4s`. Returns `{:ok, [master, media | segment_paths]}`.
  """
  @spec write_hls(Path.t(), [ISOMedia.Box.t()], keyword()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def write_hls(dir, boxes, opts \\ []) do
    File.mkdir_p!(dir)
    master_path = Path.join(dir, "master.m3u8")
    media_path = Path.join(dir, Keyword.get(opts, :media_uri, "media.m3u8"))

    with :ok <- File.write(master_path, master_playlist(boxes, opts)),
         :ok <- File.write(media_path, media_playlist(boxes, opts)),
         {:ok, segment_paths} <- ISOMedia.write_segments(dir, boxes, opts) do
      {:ok, [master_path, media_path | segment_paths]}
    end
  end

  defp seconds(%{duration_ts: d, timescale: ts}), do: d / ts

  defp validate!(boxes) do
    unless FragmentIndex.fragmented?(boxes) do
      raise ArgumentError, "hls: expected a fragmented (fragment/2) tree"
    end
  end
end
