defmodule ISOMedia.Trim do
  @moduledoc """
  Losslessly trim every track to a time range `[start_sec, end_sec)`.

  Per track: select samples by decode time (snap the start back to the nearest
  keyframe), rebuild all sample tables from the kept set, and re-base the timeline to
  zero. Kept chunk-runs from all tracks are written to a new `mdat` sorted by their
  original file offset, preserving A/V interleave. Duration headers are updated.
  Memory-safe: the new `mdat` is a segment list.
  """

  alias ISOMedia.{Box, BoxPath, MdatSource, ProgressiveBuild, SampleTable, Timescale, Trak}
  alias ISOMedia.Boxes.{ChunkOffset, EditList}

  @doc "Trim every track to `[start_sec, end_sec)`. Returns a new box tree."
  def trim(boxes, start_sec, end_sec) do
    if end_sec <= start_sec, do: raise(ArgumentError, "trim: end_sec must be > start_sec")

    ftyp = Box.child!(boxes, "ftyp", "trim")
    moov = Box.child!(boxes, "moov", "trim")
    mdats = MdatSource.collect(boxes)
    movie_ts = Trak.movie_timescale(moov)

    selections =
      moov.children
      |> Box.children("trak")
      |> Enum.map(fn trak -> select_track(trak, start_sec, end_sec) end)

    # Tag each kept chunk-run with its track index and original offset, then sort
    # globally by original offset to preserve interleave. The single-input `sort_key`
    # `{0, chunk_i}` orders each track's stco by chunk index.
    tagged =
      selections
      |> Enum.with_index()
      |> Enum.flat_map(fn {sel, ti} ->
        sel.runs
        |> Enum.with_index()
        |> Enum.map(fn {run, chunk_i} ->
          %{
            track_i: ti,
            sort_key: {0, chunk_i},
            mdats: mdats,
            offset: hd(run).offset,
            length: Enum.sum(Enum.map(run, & &1.size))
          }
        end)
      end)
      |> Enum.sort_by(& &1.offset)

    ProgressiveBuild.place(ftyp, tagged, length(selections), fn offsets_by_track, co_kind ->
      assemble_moov(moov, selections, offsets_by_track, co_kind, movie_ts)
    end)
  end

  # --- per-track selection ---

  defp select_track(trak, start_sec, end_sec) do
    ts = Trak.timescale(trak)
    start_ts = round(start_sec * ts)
    end_ts = round(end_sec * ts)

    samples = SampleTable.build(trak)

    # The requested window must actually contain a sample. (Checked before snapping —
    # otherwise snap-back could resurrect a trailing keyframe for an out-of-range
    # window and silently produce a bogus one-sample clip.)
    if not Enum.any?(samples, fn s -> s.dts >= start_ts and s.dts < end_ts end),
      do: raise(ArgumentError, "trim range selects no samples for track #{Trak.id(trak)}")

    start_index =
      case Enum.filter(samples, fn s -> s.sync? and s.dts <= start_ts end) do
        [] -> 1
        syncs -> List.last(syncs).index
      end

    kept = Enum.filter(samples, fn s -> s.index >= start_index and s.dts < end_ts end)

    snap_dts = hd(kept).dts
    lead = max(0, start_ts - snap_dts)
    visible = Enum.sum(Enum.map(kept, & &1.duration)) - lead

    %{
      trak: trak,
      ts: ts,
      kept: kept,
      runs: Enum.chunk_by(kept, & &1.chunk_index),
      lead: lead,
      visible: visible
    }
  end

  # --- moov / trak rebuild ---

  defp assemble_moov(moov, selections, offsets_by_track, co_kind, movie_ts) do
    trimmed =
      selections
      |> Enum.with_index()
      |> Enum.map(fn {sel, ti} ->
        build_trimmed_trak(sel, Map.fetch!(offsets_by_track, ti), co_kind, movie_ts)
      end)

    movie_dur =
      selections
      |> Enum.map(fn sel -> Timescale.scale(sum_durations(sel.kept), sel.ts, movie_ts) end)
      |> Enum.max(fn -> 0 end)

    children =
      moov.children
      |> drop_traks()
      |> Enum.map(fn
        %Box{type: "mvhd"} = mvhd -> Trak.set_movie_duration(mvhd, movie_dur)
        other -> other
      end)

    %{moov | children: Box.insert_after(children, "mvhd", trimmed)}
  end

  defp build_trimmed_trak(sel, stco_offsets, co_kind, movie_ts) do
    kept = sel.kept
    track_dur = sum_durations(kept)

    stsd =
      BoxPath.dig(sel.trak, ~w(mdia minf stbl stsd)) || raise ArgumentError, "trak missing stsd"

    stts = SampleTable.build_stts(Enum.map(kept, & &1.duration))
    ctts = SampleTable.build_ctts(Enum.map(kept, &(&1.pts - &1.dts)))
    stsz = SampleTable.build_stsz(Enum.map(kept, & &1.size))
    stsc = SampleTable.build_stsc(Enum.map(sel.runs, &length/1))

    stco =
      ChunkOffset.encode(%ChunkOffset{
        kind: co_kind,
        version: 0,
        flags: <<0, 0, 0>>,
        offsets: stco_offsets
      })

    stss = sync_box(kept)

    stbl_children =
      [stsd, stts] ++ opt(ctts) ++ [stsc, stsz] ++ opt(stss) ++ [stco]

    sel.trak
    |> put_stbl(stbl_children)
    |> BoxPath.update_descendant(~w(mdia mdhd), &Trak.set_media_duration(&1, track_dur))
    |> BoxPath.update_descendant(
      ["tkhd"],
      &Trak.set_track_duration(&1, Timescale.scale(track_dur, sel.ts, movie_ts))
    )
    |> put_edts(edts_for(sel, movie_ts))
  end

  # An `edts` box (containing one `elst`) for the track, or nil when there is no lead
  # to hide.
  defp edts_for(%{lead: lead} = sel, movie_ts) when lead > 0 do
    elst =
      EditList.encode(%EditList{
        version: 0,
        entries: [
          %{
            segment_duration: Timescale.scale(sel.visible, sel.ts, movie_ts),
            media_time: lead,
            rate_integer: 1,
            rate_fraction: 0
          }
        ]
      })

    %Box{type: "edts", data: nil, children: [elst]}
  end

  defp edts_for(_sel, _movie_ts), do: nil

  # Drop any inherited `edts` (the timeline is re-based), then insert the fresh one
  # (if any) immediately after `tkhd`.
  defp put_edts(trak, edts) do
    children = Box.remove(trak.children, ["edts"])
    children = if edts, do: Box.insert_after(children, "tkhd", [edts]), else: children
    %{trak | children: children}
  end

  # stss only when not every kept sample is sync.
  defp sync_box(kept) do
    if Enum.all?(kept, & &1.sync?) do
      nil
    else
      positions =
        kept
        |> Enum.with_index(1)
        |> Enum.filter(fn {s, _} -> s.sync? end)
        |> Enum.map(&elem(&1, 1))

      SampleTable.build_stss(positions)
    end
  end

  defp put_stbl(trak, stbl_children) do
    BoxPath.update_descendant(trak, ~w(mdia minf stbl), fn stbl ->
      %{stbl | children: stbl_children}
    end)
  end

  # --- small helpers ---

  defp sum_durations(samples), do: Enum.sum(Enum.map(samples, & &1.duration))
  defp opt(nil), do: []
  defp opt(box), do: [box]

  defp drop_traks(children), do: Box.remove(children, ["trak"])
end
