defmodule ISOMedia.Extract do
  @moduledoc """
  Track discovery and single-track extraction.

  `track_ids/1` and `find_trak/2` locate tracks by their `tkhd` track_id;
  `extract_track/2` (added later) produces a new single-track tree.
  """

  alias ISOMedia.Box
  alias ISOMedia.Boxes.TrackHeader

  @doc "List every track's `track_id`, in document order."
  def track_ids(boxes) do
    boxes
    |> traks()
    |> Enum.map(&track_id_of/1)
  end

  @doc "Find the `trak` box whose `tkhd` track_id matches, or `nil`."
  def find_trak(boxes, track_id) do
    boxes
    |> traks()
    |> Enum.find(fn trak -> track_id_of(trak) == track_id end)
  end

  defp traks(boxes) do
    case Enum.find(boxes, &(&1.type == "moov")) do
      nil -> []
      moov -> Enum.filter(moov.children, &(&1.type == "trak"))
    end
  end

  defp track_id_of(%Box{} = trak) do
    tkhd = Box.find([trak], ~w(trak tkhd)) || raise ArgumentError, "trak is missing tkhd"
    TrackHeader.decode(tkhd).track_id
  end
end
