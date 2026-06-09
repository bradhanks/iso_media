defmodule ISOMedia.Concat do
  @moduledoc """
  Losslessly concatenate N compatible clips end-to-end.

  Inputs must have the same track count and, per track, byte-identical `stsd` and the
  same `mdhd` timescale (so sample tables can be appended without recomputation). The
  per-track samples and `mdat` sources are handed to `ISOMedia.ProgressiveBuild`, which
  appends each input's samples (the timeline continues), rebuilds the tables, and
  assembles one `mdat` from every input's chunk-runs (each input's runs in original-offset
  order, preserving its interleave). Source edit lists are ignored.
  """

  alias ISOMedia.{Box, BoxPath, MdatSource, ProgressiveBuild, SampleTable, Trak}

  @doc "Concatenate a list of parsed trees into one. Returns a new box tree."
  def concat([]), do: raise(ArgumentError, "concat: empty input list")
  def concat([single]), do: single

  def concat([first | _] = inputs) do
    check_compatibility!(inputs)

    ftyp =
      Box.child(first, "ftyp") || raise ArgumentError, "first input has no ftyp"

    first_moov =
      Box.child(first, "moov") || raise ArgumentError, "first input has no moov"

    movie_ts = Trak.movie_timescale(first_moov)

    inputs_data =
      Enum.map(inputs, fn boxes ->
        moov = Box.child(boxes, "moov")
        tks = traks(moov)
        %{samples: Enum.map(tks, &SampleTable.build/1), mdats: MdatSource.collect(boxes)}
      end)

    ProgressiveBuild.assemble(ftyp, first_moov, inputs_data, movie_ts)
  end

  # --- compatibility ---

  defp check_compatibility!([first | rest]) do
    fmoov = moov_of(first)
    ftraks = traks(fmoov)
    count = length(ftraks)

    Enum.each(rest, fn boxes ->
      if length(traks(moov_of(boxes))) != count,
        do: raise(ArgumentError, "concat: inputs have different track count")
    end)

    for ti <- 0..(count - 1)//1 do
      ref_stsd = stsd_data(Enum.at(ftraks, ti))
      ref_ts = Trak.timescale(Enum.at(ftraks, ti))

      Enum.each(rest, fn boxes ->
        t = Enum.at(traks(moov_of(boxes)), ti)

        if stsd_data(t) != ref_stsd,
          do:
            raise(
              ArgumentError,
              "concat: track #{ti + 1} stsd differs between inputs (incompatible codec config)"
            )

        if Trak.timescale(t) != ref_ts,
          do: raise(ArgumentError, "concat: track #{ti + 1} timescale differs between inputs")
      end)
    end
  end

  # --- small helpers (shared with the compatibility checks) ---

  defp moov_of(boxes),
    do: Box.child(boxes, "moov") || raise(ArgumentError, "input has no moov")

  defp traks(moov), do: Box.children(moov.children, "trak")

  defp stsd_data(trak),
    do:
      (BoxPath.dig(trak, ~w(mdia minf stbl stsd)) ||
         raise(ArgumentError, "track missing stsd")).data
end
