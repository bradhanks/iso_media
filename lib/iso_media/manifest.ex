defmodule ISOMedia.Manifest do
  @moduledoc """
  Manifest-agnostic computations shared by the HLS and DASH generators: the per-track
  codec strings, the video resolution, and the peak per-segment bandwidth. Pure, read-only
  functions over a fragmented (`fragment/2`-shaped) tree — one home for the codec/bandwidth
  logic so `HLS` and `DASH` only format (DRY).
  """
  alias ISOMedia.FragmentIndex

  @doc "Track `%ISOMedia.TrackInfo{}` structs, video first then audio."
  @spec track_infos([ISOMedia.Box.t()]) :: [ISOMedia.TrackInfo.t()]
  def track_infos(boxes) do
    boxes
    |> ISOMedia.track_ids()
    |> Enum.map(&ISOMedia.track_info(boxes, &1))
    |> Enum.sort_by(fn ti -> if ti.type == :video, do: 0, else: 1 end)
  end

  @doc "Comma-joined RFC 6381 codec string for every track, e.g. `avc1.64000a,mp4a.40.2`."
  @spec codecs([ISOMedia.Box.t()]) :: String.t()
  def codecs(boxes), do: track_infos(boxes) |> Enum.map_join(",", & &1.codec)

  @doc "The video track's `{width, height}`, or `nil` when there is no video track."
  @spec video_dimensions([ISOMedia.Box.t()]) :: {pos_integer(), pos_integer()} | nil
  def video_dimensions(boxes) do
    case Enum.find(track_infos(boxes), &(&1.type == :video)) do
      nil -> nil
      ti -> {ti.width, ti.height}
    end
  end

  @doc "The video resolution as `WxH` (e.g. `128x96`), or `nil` when audio-only."
  @spec resolution([ISOMedia.Box.t()]) :: String.t() | nil
  def resolution(boxes) do
    case video_dimensions(boxes) do
      nil -> nil
      {w, h} -> "#{w}x#{h}"
    end
  end

  @doc """
  Peak per-segment bit rate in bits/sec (integer `ceil` over the `moof` spans). Both HLS
  `BANDWIDTH` and DASH `@bandwidth` are this peak segment rate.
  """
  @spec peak_bandwidth([ISOMedia.Box.t()]) :: non_neg_integer()
  def peak_bandwidth(boxes) do
    FragmentIndex.fragment_spans(boxes)
    |> Enum.map(fn s -> div(s.bytes * 8 * s.timescale + s.duration_ts - 1, s.duration_ts) end)
    |> Enum.max()
  end
end
