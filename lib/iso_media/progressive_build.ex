defmodule ISOMedia.ProgressiveBuild do
  @moduledoc """
  Assemble a progressive `[ftyp, moov, mdat]` tree from one or more inputs' per-track
  samples + `mdat` sources. Shared by `Concat` (N inputs) and `Defragment` (one input).
  Preserves interleave (runs sorted by original offset for the byte layout) while keeping
  logical `{input, chunk}` order for each track's `stco`.
  """
  alias ISOMedia.{Box, BoxPath, Layout, MdatSource, SampleTable, Timescale, Trak}
  alias ISOMedia.Boxes.ChunkOffset

  @doc """
  `inputs_data` is a list of `%{samples: [[%Sample{}] per track], mdats: collect/1 records}`.
  `base_moov` supplies the trak skeletons and non-trak children (its `trak`s' `stbl` is
  fully replaced; any `mvex` must already be stripped by the caller). Returns
  `[ftyp, moov, mdat]`.
  """
  def assemble(ftyp, base_moov, inputs_data, movie_ts) do
    track_count = length(traks(base_moov))

    tagged =
      inputs_data
      |> Enum.with_index()
      |> Enum.flat_map(fn {d, input_i} ->
        d.samples
        |> Enum.with_index()
        |> Enum.flat_map(fn {samples, ti} ->
          samples
          |> Enum.chunk_by(& &1.chunk_index)
          |> Enum.with_index()
          |> Enum.map(fn {run, chunk_i} ->
            %{
              track_i: ti,
              # stco order keeps each track's chunks in {input, chunk} sequence even
              # though the byte layout (offset order) interleaves the inputs.
              sort_key: {input_i, chunk_i},
              mdats: d.mdats,
              offset: hd(run).offset,
              length: Enum.sum(Enum.map(run, & &1.size))
            }
          end)
        end)
        |> Enum.sort_by(& &1.offset)
      end)

    place(ftyp, tagged, track_count, fn offsets_by_track, co_kind ->
      assemble_moov(base_moov, inputs_data, track_count, offsets_by_track, co_kind, movie_ts)
    end)
  end

  @doc """
  The shared progressive placement skeleton, used by `assemble/4` (Concat/Defragment) and
  `ISOMedia.Trim`. `tagged` is the chunk-runs to lay out — each a map with `:track_i`,
  `:sort_key` (the per-track stco ordering), `:mdats`, `:offset`, `:length` — already sorted
  by original offset (interleave order). `assemble_moov` is `fn offsets_by_track, co_kind ->
  moov_box`; it is called with dummy offsets to measure the layout (deciding stco↔co64 and
  the mdat start), then once more with the real offsets. Returns `[ftyp, moov, mdat]`.
  """
  @spec place(Box.t(), [map()], non_neg_integer(), (map(), :stco | :co64 -> Box.t())) ::
          [Box.t()]
  def place(ftyp, tagged, track_count, assemble_moov) do
    total = Enum.sum(Enum.map(tagged, & &1.length))
    mdat_mode = Box.size_mode_for_body(total)
    mdat_header = Box.header_base(mdat_mode)

    runs_per_track =
      Map.new(0..(track_count - 1)//1, fn ti -> {ti, Enum.count(tagged, &(&1.track_i == ti))} end)

    dummy = Map.new(runs_per_track, fn {ti, n} -> {ti, List.duplicate(0, n)} end)

    # Decide co64 vs stco from a conservative upper bound (co64 tables + 16-byte header).
    bound =
      Layout.box_size(ftyp) + Layout.box_size(assemble_moov.(dummy, :co64)) + 16 + total

    co_kind = ChunkOffset.kind_for(bound)

    moov0 = assemble_moov.(dummy, co_kind)
    mdat_payload_start = Layout.box_size(ftyp) + Layout.box_size(moov0) + mdat_header

    {placed, _} =
      Enum.map_reduce(tagged, mdat_payload_start, fn run, pos ->
        {Map.put(run, :new_offset, pos), pos + run.length}
      end)

    offsets_by_track =
      Map.new(0..(track_count - 1)//1, fn ti ->
        offs =
          placed
          |> Enum.filter(&(&1.track_i == ti))
          |> Enum.sort_by(& &1.sort_key)
          |> Enum.map(& &1.new_offset)

        {ti, offs}
      end)

    moov_final = assemble_moov.(offsets_by_track, co_kind)

    segments =
      Enum.map(placed, fn run -> MdatSource.segment(run.mdats, run.offset, run.length) end)

    mdat = MdatSource.synthesized_mdat(segments, mdat_mode, mdat_payload_start)

    [ftyp, moov_final, mdat]
  end

  # --- moov / trak rebuild ---

  defp assemble_moov(base_moov, inputs_data, track_count, offsets_by_track, co_kind, movie_ts) do
    base_traks = traks(base_moov)

    joined =
      for ti <- 0..(track_count - 1)//1 do
        base = Enum.at(base_traks, ti)
        samples = Enum.flat_map(inputs_data, &Enum.at(&1.samples, ti))

        run_lengths =
          Enum.flat_map(inputs_data, fn d ->
            Enum.at(d.samples, ti) |> Enum.chunk_by(& &1.chunk_index) |> Enum.map(&length/1)
          end)

        build_joined_trak(
          base,
          samples,
          run_lengths,
          Map.fetch!(offsets_by_track, ti),
          co_kind,
          Trak.timescale(base),
          movie_ts
        )
      end

    movie_dur =
      for ti <- 0..(track_count - 1)//1 do
        samples = Enum.flat_map(inputs_data, &Enum.at(&1.samples, ti))

        Timescale.scale(
          Enum.sum(Enum.map(samples, & &1.duration)),
          Trak.timescale(Enum.at(base_traks, ti)),
          movie_ts
        )
      end
      |> Enum.max(fn -> 0 end)

    children =
      base_moov.children
      |> Box.remove(["trak"])
      |> Enum.map(fn
        %Box{type: "mvhd"} = mvhd -> Trak.set_movie_duration(mvhd, movie_dur)
        other -> other
      end)

    %{base_moov | children: Box.insert_after(children, "mvhd", joined)}
  end

  defp build_joined_trak(base, samples, run_lengths, stco_offsets, co_kind, track_ts, movie_ts) do
    track_dur = Enum.sum(Enum.map(samples, & &1.duration))

    stsd = BoxPath.dig(base, ~w(mdia minf stbl stsd)) || raise ArgumentError, "track missing stsd"
    stts = SampleTable.build_stts(Enum.map(samples, & &1.duration))
    ctts = SampleTable.build_ctts(Enum.map(samples, &(&1.pts - &1.dts)))
    stsz = SampleTable.build_stsz(Enum.map(samples, & &1.size))
    stsc = SampleTable.build_stsc(run_lengths)

    stco =
      ChunkOffset.encode(%ChunkOffset{
        kind: co_kind,
        version: 0,
        flags: <<0, 0, 0>>,
        offsets: stco_offsets
      })

    stss =
      if Enum.all?(samples, & &1.sync?),
        do: nil,
        else: SampleTable.build_stss(sync_positions(samples))

    stbl_children = [stsd, stts] ++ opt(ctts) ++ [stsc, stsz] ++ opt(stss) ++ [stco]

    base
    |> put_stbl(stbl_children)
    |> drop_edts()
    |> BoxPath.update_descendant(~w(mdia mdhd), &Trak.set_media_duration(&1, track_dur))
    |> BoxPath.update_descendant(
      ["tkhd"],
      &Trak.set_track_duration(&1, Timescale.scale(track_dur, track_ts, movie_ts))
    )
  end

  defp sync_positions(samples) do
    samples
    |> Enum.with_index(1)
    |> Enum.filter(fn {s, _} -> s.sync? end)
    |> Enum.map(&elem(&1, 1))
  end

  defp traks(moov), do: Box.children(moov.children, "trak")

  defp opt(nil), do: []
  defp opt(box), do: [box]

  defp drop_edts(trak), do: %{trak | children: Box.remove(trak.children, ["edts"])}

  defp put_stbl(trak, stbl_children) do
    BoxPath.update_descendant(trak, ~w(mdia minf stbl), fn stbl ->
      %{stbl | children: stbl_children}
    end)
  end
end
