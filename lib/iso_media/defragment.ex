defmodule ISOMedia.Defragment do
  @moduledoc """
  Repack a fragmented MP4 (`moof`/`traf`/`trun`) into a standard progressive
  `[ftyp, moov, mdat]` — a pure metadata edit, no transcoding. Samples come from
  `FragmentIndex`; the output is assembled by `ISOMedia.ProgressiveBuild`, so the
  `mdat` is a recursive segment list referencing each fragment's bytes (memory-safe).
  """
  alias ISOMedia.{Box, FragmentIndex, MdatSource, ProgressiveBuild, Trak}

  @doc "Defragment one parsed fragmented tree into a progressive tree."
  def defragment(boxes) do
    unless FragmentIndex.fragmented?(boxes) do
      raise ArgumentError, "defragment: not a fragmented file (needs moov/mvex + moof)"
    end

    ftyp = Box.child(boxes, "ftyp") || raise ArgumentError, "defragment: no ftyp"
    moov = Box.child(boxes, "moov") || raise ArgumentError, "defragment: no moov"

    base_traks = Box.children(moov.children, "trak")
    track_ids = Enum.map(base_traks, &Trak.id/1)
    per_track = Enum.map(track_ids, &FragmentIndex.samples(boxes, &1))
    movie_ts = Trak.movie_timescale(moov)

    base_moov = %{moov | children: Box.remove(moov.children, ["mvex"])}
    inputs_data = [%{samples: per_track, mdats: MdatSource.collect(boxes)}]

    ProgressiveBuild.assemble(ftyp, base_moov, inputs_data, movie_ts)
  end
end
