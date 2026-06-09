defmodule ISOMedia.Streaming do
  @moduledoc """
  The delivery layer: getting a media tree onto the wire.

  Where `ISOMedia` itself is about box surgery (parse, edit, trim, concat, fragment,
  serialize), this module groups the packaging and serving concerns that build on a
  fragmented (CMAF-shaped) tree:

    * **CMAF segmentation** — `split_segments/1`, `write_segments/3`.
    * **HLS** — `hls_media_playlist/2`, `hls_master_playlist/2`, `write_hls/3`.
    * **DASH** — `dash_manifest/2`, `write_dash/3`.
    * **HTTP byte-range serving** — `seek_index/1`, `read_range/3`, `stream_range/4`,
      `content_length/1`, for answering `Range` requests over a tree's serialization
      without materializing it.

  This is the one place that knows which implementation module (`Segment`, `HLS`,
  `DASH`, `SeekIndex`) backs each delivery operation; the convenience wrappers on
  `ISOMedia` delegate here. A typical pipeline:

      boxes
      |> ISOMedia.fragment()
      |> ISOMedia.Streaming.write_hls(dir)
  """

  alias ISOMedia.{DASH, HLS, SeekIndex, Segment}

  @type tree :: [ISOMedia.Box.t()]

  # --- CMAF segmentation ---

  @doc "Split a fragmented tree into a CMAF init segment + media segments. See `ISOMedia.Segment.split/1`."
  @spec split_segments(tree()) :: %{init: tree(), segments: [tree()]}
  def split_segments(boxes), do: Segment.split(boxes)

  @doc "Write a fragmented tree's init + media segment files into `dir`. See `ISOMedia.Segment.write_segments/3`."
  @spec write_segments(Path.t(), tree(), keyword()) :: {:ok, [Path.t()]} | {:error, term()}
  def write_segments(dir, boxes, opts \\ []), do: Segment.write_segments(dir, boxes, opts)

  # --- HLS ---

  @doc "Generate the HLS media playlist (`.m3u8`) for a fragmented tree. See `ISOMedia.HLS.media_playlist/2`."
  @spec hls_media_playlist(tree(), keyword()) :: String.t()
  def hls_media_playlist(boxes, opts \\ []), do: HLS.media_playlist(boxes, opts)

  @doc "Generate the HLS multivariant playlist (`.m3u8`) for a fragmented tree. See `ISOMedia.HLS.master_playlist/2`."
  @spec hls_master_playlist(tree(), keyword()) :: String.t()
  def hls_master_playlist(boxes, opts \\ []), do: HLS.master_playlist(boxes, opts)

  @doc "Write a full HLS bundle (playlists + segments) into `dir`. See `ISOMedia.HLS.write_hls/3`."
  @spec write_hls(Path.t(), tree(), keyword()) :: {:ok, [Path.t()]}
  def write_hls(dir, boxes, opts \\ []), do: HLS.write_hls(dir, boxes, opts)

  # --- DASH ---

  @doc "Generate the DASH MPD (`.mpd`) for a fragmented tree. See `ISOMedia.DASH.manifest/2`."
  @spec dash_manifest(tree(), keyword()) :: String.t()
  def dash_manifest(boxes, opts \\ []), do: DASH.manifest(boxes, opts)

  @doc "Write a full DASH bundle (MPD + segments) into `dir`. See `ISOMedia.DASH.write_dash/3`."
  @spec write_dash(Path.t(), tree(), keyword()) :: {:ok, [Path.t()]}
  def write_dash(dir, boxes, opts \\ []), do: DASH.write_dash(dir, boxes, opts)

  # --- HTTP byte-range serving ---

  @doc "Build a random-access index over a tree's serialization. See `ISOMedia.SeekIndex.build/1`."
  @spec seek_index(tree() | ISOMedia.Box.t()) :: ISOMedia.SeekIndex.t()
  def seek_index(boxes), do: SeekIndex.build(boxes)

  @doc "Read bytes `[offset, offset+length)` of a tree's serialization. See `ISOMedia.SeekIndex.read_range/3`."
  @spec read_range(ISOMedia.SeekIndex.t(), non_neg_integer(), non_neg_integer()) :: binary()
  def read_range(index, offset, length), do: SeekIndex.read_range(index, offset, length)

  @doc "Lazily stream bytes `[offset, offset+length)` of a tree's serialization. See `ISOMedia.SeekIndex.stream_range/4`."
  @spec stream_range(ISOMedia.SeekIndex.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          Enumerable.t()
  def stream_range(index, offset, length, chunk_size \\ 65_536),
    do: SeekIndex.stream_range(index, offset, length, chunk_size)

  @doc "Total serialized size of the indexed tree (HTTP `Content-Length`). See `ISOMedia.SeekIndex.content_length/1`."
  @spec content_length(ISOMedia.SeekIndex.t()) :: non_neg_integer()
  def content_length(index), do: SeekIndex.content_length(index)
end
