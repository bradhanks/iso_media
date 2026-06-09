defmodule ISOMedia.Trak do
  @moduledoc """
  Cross-cutting accessors and header edits for a `trak`/`moov`, shared by the editing
  operations (`Trim`, `ProgressiveBuild`, `Extract`, `Concat`, `Defragment`, `Fragment`,
  `FragmentIndex`). One home for "read a track's id/timescale" and "set a duration
  header", so those one-liners stop being re-derived per module.
  """

  alias ISOMedia.{Box, BoxPath}
  alias ISOMedia.Boxes.{MediaHeader, MovieHeader, TrackHeader}

  @doc "A track's `tkhd` track_id."
  @spec id(Box.t()) :: non_neg_integer()
  def id(trak), do: TrackHeader.decode(tkhd!(trak)).track_id

  @doc "A track's media timescale (from `mdhd`)."
  @spec timescale(Box.t()) :: pos_integer()
  def timescale(trak), do: MediaHeader.decode(mdhd!(trak)).timescale

  @doc "A movie's timescale (from `mvhd`), or `1` when absent."
  @spec movie_timescale(Box.t()) :: pos_integer()
  def movie_timescale(moov) do
    case BoxPath.dig(moov, ["mvhd"]) do
      %Box{} = mvhd -> MovieHeader.decode(mvhd).timescale
      nil -> 1
    end
  end

  @doc "Re-encode an `mdhd` box with a new media-timescale `duration`."
  @spec set_media_duration(Box.t(), non_neg_integer()) :: Box.t()
  def set_media_duration(mdhd, dur) do
    h = MediaHeader.decode(mdhd)
    MediaHeader.encode(%{h | duration: dur})
  end

  @doc "Re-encode a `tkhd` box with a new movie-timescale `duration`."
  @spec set_track_duration(Box.t(), non_neg_integer()) :: Box.t()
  def set_track_duration(tkhd, dur) do
    h = TrackHeader.decode(tkhd)
    TrackHeader.encode(%{h | duration: dur})
  end

  @doc "Re-encode an `mvhd` box with a new movie-timescale `duration`."
  @spec set_movie_duration(Box.t(), non_neg_integer()) :: Box.t()
  def set_movie_duration(mvhd, dur) do
    h = MovieHeader.decode(mvhd)
    MovieHeader.encode(%{h | duration: dur})
  end

  defp tkhd!(trak),
    do: BoxPath.dig(trak, ["tkhd"]) || raise(ArgumentError, "trak is missing tkhd")

  defp mdhd!(trak),
    do: BoxPath.dig(trak, ~w(mdia mdhd)) || raise(ArgumentError, "trak is missing mdia/mdhd")
end
