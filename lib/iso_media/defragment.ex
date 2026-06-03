defmodule ISOMedia.Defragment do
  @moduledoc """
  Repack a fragmented MP4 (`moof`/`traf`/`trun`) into a standard progressive
  `[ftyp, moov, mdat]` — a pure metadata edit, no transcoding. Samples come from
  `FragmentIndex`; the output is assembled by `ISOMedia.ProgressiveBuild`, so the
  `mdat` is a recursive segment list referencing each fragment's bytes (memory-safe).
  """
  alias ISOMedia.{Box, BoxPath, FragmentIndex, MdatSource, ProgressiveBuild}
  alias ISOMedia.Boxes.{MovieHeader, TrackHeader}

  @doc "Defragment one parsed fragmented tree into a progressive tree."
  def defragment(boxes) do
    unless FragmentIndex.fragmented?(boxes) do
      raise ArgumentError, "defragment: not a fragmented file (needs moov/mvex + moof)"
    end

    ftyp = Enum.find(boxes, &(&1.type == "ftyp")) || raise ArgumentError, "defragment: no ftyp"
    moov = Enum.find(boxes, &(&1.type == "moov")) || raise ArgumentError, "defragment: no moov"

    base_traks = Enum.filter(moov.children, &(&1.type == "trak"))
    track_ids = Enum.map(base_traks, &track_id_of/1)
    per_track = Enum.map(track_ids, &FragmentIndex.samples(boxes, &1))

    movie_ts =
      case BoxPath.dig(moov, ["mvhd"]) do
        %Box{} = mvhd -> MovieHeader.decode(mvhd).timescale
        nil -> 1
      end

    base_moov = %{moov | children: Enum.reject(moov.children, &(&1.type == "mvex"))}
    inputs_data = [%{samples: per_track, mdats: MdatSource.collect(boxes)}]

    ProgressiveBuild.assemble(ftyp, base_moov, inputs_data, movie_ts)
  end

  defp track_id_of(trak), do: TrackHeader.decode(BoxPath.dig(trak, ["tkhd"])).track_id
end
