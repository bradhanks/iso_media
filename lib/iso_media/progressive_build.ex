defmodule ISOMedia.ProgressiveBuild do
  @moduledoc """
  Assemble a progressive `[ftyp, moov, mdat]` tree from one or more inputs' per-track
  samples + `mdat` sources. Shared by `Concat` (N inputs) and `Defragment` (one input).
  Preserves interleave (runs sorted by original offset for the byte layout) while keeping
  logical `{input, chunk}` order for each track's `stco`.
  """
  alias ISOMedia.{Box, BoxPath, Layout, MdatSource, SampleTable}
  alias ISOMedia.Boxes.{ChunkOffset, MediaHeader, MovieHeader, TrackHeader}

  @uint32_max 0xFFFFFFFF

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
              input_i: input_i,
              track_i: ti,
              chunk_i: chunk_i,
              mdats: d.mdats,
              offset: hd(run).offset,
              length: Enum.sum(Enum.map(run, & &1.size))
            }
          end)
        end)
        |> Enum.sort_by(& &1.offset)
      end)

    total = Enum.sum(Enum.map(tagged, & &1.length))
    {mdat_mode, mdat_header} = if 8 + total > @uint32_max, do: {:large, 16}, else: {:compact, 8}

    runs_per_track =
      Map.new(0..(track_count - 1)//1, fn ti -> {ti, Enum.count(tagged, &(&1.track_i == ti))} end)

    dummy = fn -> Map.new(runs_per_track, fn {ti, n} -> {ti, List.duplicate(0, n)} end) end

    bound =
      Layout.box_size(ftyp) +
        Layout.box_size(
          assemble_moov(base_moov, inputs_data, track_count, dummy.(), :co64, movie_ts)
        ) +
        16 + total

    co_kind = if bound > @uint32_max, do: :co64, else: :stco

    moov0 = assemble_moov(base_moov, inputs_data, track_count, dummy.(), co_kind, movie_ts)
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
          |> Enum.sort_by(&{&1.input_i, &1.chunk_i})
          |> Enum.map(& &1.new_offset)

        {ti, offs}
      end)

    moov_final =
      assemble_moov(base_moov, inputs_data, track_count, offsets_by_track, co_kind, movie_ts)

    segments =
      Enum.map(placed, fn run -> MdatSource.segment(run.mdats, run.offset, run.length) end)

    mdat = %Box{type: "mdat", data: segments, size_mode: mdat_mode}

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
          track_timescale(base),
          movie_ts
        )
      end

    movie_dur =
      for ti <- 0..(track_count - 1)//1 do
        samples = Enum.flat_map(inputs_data, &Enum.at(&1.samples, ti))

        scale(
          Enum.sum(Enum.map(samples, & &1.duration)),
          track_timescale(Enum.at(base_traks, ti)),
          movie_ts
        )
      end
      |> Enum.max(fn -> 0 end)

    children =
      base_moov.children
      |> Enum.reject(&(&1.type == "trak"))
      |> Enum.map(fn
        %Box{type: "mvhd"} = mvhd -> set_mvhd_duration(mvhd, movie_dur)
        other -> other
      end)

    %{base_moov | children: insert_traks(children, joined)}
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
    |> BoxPath.update_descendant(~w(mdia mdhd), &set_mdhd_duration(&1, track_dur))
    |> BoxPath.update_descendant(
      ["tkhd"],
      &set_tkhd_duration(&1, scale(track_dur, track_ts, movie_ts))
    )
  end

  defp sync_positions(samples) do
    samples
    |> Enum.with_index(1)
    |> Enum.filter(fn {s, _} -> s.sync? end)
    |> Enum.map(&elem(&1, 1))
  end

  defp traks(moov), do: Enum.filter(moov.children, &(&1.type == "trak"))
  defp track_timescale(trak), do: MediaHeader.decode(BoxPath.dig(trak, ~w(mdia mdhd))).timescale

  # Integer round-half-up (stays in arbitrary-precision integers — no float precision
  # loss when value*to_ts exceeds 2^53 for long media).
  defp scale(value, from_ts, to_ts), do: div(value * to_ts + div(from_ts, 2), from_ts)
  defp opt(nil), do: []
  defp opt(box), do: [box]

  defp drop_edts(trak), do: %{trak | children: Enum.reject(trak.children, &(&1.type == "edts"))}

  defp put_stbl(trak, stbl_children) do
    BoxPath.update_descendant(trak, ~w(mdia minf stbl), fn stbl ->
      %{stbl | children: stbl_children}
    end)
  end

  defp set_mdhd_duration(mdhd, dur) do
    h = MediaHeader.decode(mdhd)
    MediaHeader.encode(%{h | duration: dur})
  end

  defp set_tkhd_duration(tkhd, dur) do
    h = TrackHeader.decode(tkhd)
    TrackHeader.encode(%{h | duration: dur})
  end

  defp set_mvhd_duration(mvhd, dur) do
    h = MovieHeader.decode(mvhd)
    MovieHeader.encode(%{h | duration: dur})
  end

  defp insert_traks(children, traks) do
    idx = Enum.find_index(children, &(&1.type == "mvhd"))
    at = if idx, do: idx + 1, else: 0
    {pre, post} = Enum.split(children, at)
    pre ++ traks ++ post
  end
end
