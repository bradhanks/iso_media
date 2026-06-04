defmodule ISOMedia.Fragment do
  @moduledoc """
  Repack a progressive MP4 into a single multiplexed fragmented tree
  `[ftyp, moov(+mvex), moof, mdat, …]`. Keyframe-aligned (a fragment starts on a sync
  sample so it is independently decodable), lossless (sample bytes via a Phase 8
  segment-list `mdat`), memory-safe. The inverse of `ISOMedia.Defragment`.
  """

  alias ISOMedia.{Box, Layout, MdatSource}
  alias ISOMedia.Boxes.{TrackFragmentDecodeTime, TrackFragmentHeader, TrackRun}

  @non_sync 0x00010000

  @doc """
  Boundary dts values (in the given samples' timescale): greedily take the first sync
  sample, then each next sync sample whose dts ≥ previous boundary + `target_ts`.
  """
  def boundaries(samples, target_ts) do
    syncs = Enum.filter(samples, & &1.sync?)

    {rev, _last} =
      Enum.reduce(syncs, {[], nil}, fn s, {acc, last} ->
        if last == nil or s.dts >= last + target_ts,
          do: {[s.dts | acc], s.dts},
          else: {acc, last}
      end)

    Enum.reverse(rev)
  end

  @doc """
  Partition `samples` into one run per boundary: run `i` is the samples whose dts is in
  `[boundaries[i], boundaries[i+1])` (the last run is open-ended). `boundaries` must be in
  the same timescale as the samples, ascending.
  """
  def windows(samples, boundaries) do
    boundaries
    |> Enum.with_index()
    |> Enum.map(fn {b, i} ->
      next = Enum.at(boundaries, i + 1)
      Enum.filter(samples, fn s -> s.dts >= b and (next == nil or s.dts < next) end)
    end)
  end

  @doc false
  # Build one fragment's {moof, mdat} from per-track sample runs (aligned to `metas`).
  # data_offsets are resolved in two passes: build the moof with placeholder offsets to
  # learn its exact serialized size, then rebuild with real moof-relative offsets.
  def build_fragment(seq, runs_per_track, metas, mdats) do
    active =
      metas
      |> Enum.zip(runs_per_track)
      |> Enum.reject(fn {_m, run} -> run == [] end)

    moof0 = build_moof(seq, active, fn _i -> 0 end)
    payload_start = Layout.box_size(moof0) + 8

    {offsets, _} =
      Enum.map_reduce(active, payload_start, fn {_m, run}, pos ->
        {pos, pos + Enum.sum(Enum.map(run, & &1.size))}
      end)

    moof = build_moof(seq, active, fn i -> Enum.at(offsets, i) end)

    segments =
      Enum.flat_map(active, fn {_m, run} ->
        Enum.map(run, fn smp -> MdatSource.segment(mdats, smp.offset, smp.size) end)
      end)

    {moof, %Box{type: "mdat", size_mode: :compact, data: segments}}
  end

  defp build_moof(seq, active, offset_fun) do
    mfhd = %Box{type: "mfhd", data: <<0::32, seq::32>>}

    trafs =
      active
      |> Enum.with_index()
      |> Enum.map(fn {{meta, run}, i} -> build_traf(meta, run, offset_fun.(i)) end)

    %Box{type: "moof", children: [mfhd | trafs]}
  end

  defp build_traf(meta, run, data_offset) do
    tfhd =
      TrackFragmentHeader.encode(%TrackFragmentHeader{
        track_id: meta.track_id,
        default_base_is_moof?: true
      })

    tfdt =
      TrackFragmentDecodeTime.encode(%TrackFragmentDecodeTime{
        version: 1,
        base_media_decode_time: hd(run).dts
      })

    trun =
      TrackRun.encode(%TrackRun{
        version: 0,
        sample_count: length(run),
        data_offset: data_offset,
        first_sample_flags: nil,
        samples:
          Enum.map(run, fn smp ->
            %{
              duration: smp.duration,
              size: smp.size,
              flags: if(smp.sync?, do: 0, else: @non_sync),
              composition_offset: smp.pts - smp.dts
            }
          end)
      })

    %Box{type: "traf", children: [tfhd, tfdt, trun]}
  end
end
