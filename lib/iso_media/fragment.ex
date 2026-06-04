defmodule ISOMedia.Fragment do
  @moduledoc """
  Repack a progressive MP4 into a single multiplexed fragmented tree
  `[ftyp, moov(+mvex), moof, mdat, …]`. Keyframe-aligned (a fragment starts on a sync
  sample so it is independently decodable), lossless (sample bytes via a Phase 8
  segment-list `mdat`), memory-safe. The inverse of `ISOMedia.Defragment`.
  """

  alias ISOMedia.{Box, BoxPath, Layout, MdatSource, SampleTable, Timescale}

  alias ISOMedia.Boxes.{
    ChunkOffset,
    Handler,
    MediaHeader,
    TrackExtends,
    TrackFragmentDecodeTime,
    TrackFragmentHeader,
    TrackHeader,
    TrackRun
  }

  @non_sync 0x00010000

  @doc "Repack a progressive tree into a multiplexed fragmented tree. `opts[:target_duration]` seconds (default 2.0)."
  @spec fragment(ISOMedia.tree(), keyword()) :: ISOMedia.tree()
  def fragment(boxes, opts \\ []) do
    target_sec = Keyword.get(opts, :target_duration, 2.0)
    ftyp = Enum.find(boxes, &(&1.type == "ftyp")) || raise ArgumentError, "fragment: no ftyp"
    moov = Enum.find(boxes, &(&1.type == "moov")) || raise ArgumentError, "fragment: no moov"
    mdats = MdatSource.collect(boxes)

    metas =
      moov.children
      |> Enum.filter(&(&1.type == "trak"))
      |> Enum.map(fn trak ->
        tid = TrackHeader.decode(BoxPath.dig(trak, ["tkhd"])).track_id

        %{
          track_id: tid,
          timescale: MediaHeader.decode(BoxPath.dig(trak, ~w(mdia mdhd))).timescale,
          handler: Handler.decode(BoxPath.dig(trak, ~w(mdia hdlr))).handler_type,
          samples: ISOMedia.samples(boxes, tid),
          trak: trak
        }
      end)

    if metas == [], do: raise(ArgumentError, "fragment: moov has no trak children")
    driver = Enum.find(metas, &(&1.handler == "vide")) || hd(metas)
    target_ts = round(target_sec * driver.timescale)
    bounds = boundaries(driver.samples, target_ts)

    if bounds == [] and driver.samples != [] do
      raise ArgumentError,
            "fragment: driver track #{driver.track_id} has samples but no sync samples; " <>
              "cannot determine keyframe-aligned fragment boundaries"
    end

    windows_per_track =
      Enum.map(metas, fn m ->
        bts = Enum.map(bounds, fn b -> Timescale.scale(b, driver.timescale, m.timescale) end)
        windows(m.samples, bts)
      end)

    moof_mdats =
      windows_per_track
      |> Enum.zip_with(& &1)
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {runs_per_track, seq} ->
        {moof, mdat} = build_fragment(seq, runs_per_track, metas, mdats)
        [moof, mdat]
      end)

    [ftyp, build_init_moov(moov, metas) | moof_mdats]
  end

  defp build_init_moov(moov, metas) do
    mvhd = Enum.find(moov.children, &(&1.type == "mvhd"))

    trex_boxes =
      Enum.map(metas, fn m ->
        TrackExtends.encode(%TrackExtends{
          track_id: m.track_id,
          default_sample_description_index: 1,
          default_sample_duration: 0,
          default_sample_size: 0,
          default_sample_flags: 0
        })
      end)

    mvex = %Box{type: "mvex", children: trex_boxes}
    init_traks = Enum.map(metas, fn m -> build_init_trak(m.trak) end)
    others = Enum.reject(moov.children, &(&1.type in ~w(trak mvhd mvex)))
    children = Enum.reject([mvhd] ++ init_traks ++ [mvex] ++ others, &is_nil/1)
    %{moov | children: children}
  end

  defp build_init_trak(trak) do
    stsd = BoxPath.dig(trak, ~w(mdia minf stbl stsd)) || raise ArgumentError, "track missing stsd"

    empty = [
      stsd,
      SampleTable.build_stts([]),
      SampleTable.build_stsc([]),
      SampleTable.build_stsz([]),
      ChunkOffset.encode(%ChunkOffset{kind: :stco, version: 0, flags: <<0, 0, 0>>, offsets: []})
    ]

    trak
    |> Map.update!(:children, &Enum.reject(&1, fn c -> c.type == "edts" end))
    |> BoxPath.update_descendant(~w(mdia minf stbl), fn stbl -> %{stbl | children: empty} end)
  end

  @doc """
  Boundary dts values (in the given samples' timescale): greedily take the first sync
  sample, then each next sync sample whose dts ≥ previous boundary + `target_ts`.
  """
  @spec boundaries([ISOMedia.Sample.t()], non_neg_integer()) :: [non_neg_integer()]
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

  The **first window is open-ended on the low end**: it includes every sample before
  `boundaries[1]`, regardless of whether its dts is less than `boundaries[0]`. This
  preserves any leading non-sync samples (frames before the first keyframe) so that
  fragmenting remains lossless.
  """
  @spec windows([ISOMedia.Sample.t()], [non_neg_integer()]) :: [[ISOMedia.Sample.t()]]
  def windows(samples, boundaries) do
    boundaries
    |> Enum.with_index()
    |> Enum.map(fn {b, i} ->
      next = Enum.at(boundaries, i + 1)
      # The first window is open-ended on the low end: any samples before the first
      # boundary (e.g. leading non-sync frames) must be kept so fragmenting is lossless.
      Enum.filter(samples, fn s ->
        (i == 0 or s.dts >= b) and (next == nil or s.dts < next)
      end)
    end)
  end

  @doc false
  # Build one fragment's {moof, mdat} from per-track sample runs (aligned to `metas`).
  # data_offsets are resolved in two passes: build the moof with placeholder offsets to
  # learn its exact serialized size, then rebuild with real moof-relative offsets.
  @spec build_fragment(pos_integer(), [[ISOMedia.Sample.t()]], [map()], [map()]) ::
          {ISOMedia.Box.t(), ISOMedia.Box.t()}
  def build_fragment(seq, runs_per_track, metas, mdats) do
    active =
      metas
      |> Enum.zip(runs_per_track)
      |> Enum.reject(fn {_m, run} -> run == [] end)

    moof0 = build_moof(seq, Enum.map(active, fn {m, run} -> {m, run, 0} end))
    # 8 = compact mdat header (size::32 + type::32)
    payload_start = Layout.box_size(moof0) + 8

    {placed, _} =
      Enum.map_reduce(active, payload_start, fn {m, run}, pos ->
        {{m, run, pos}, pos + Enum.sum(Enum.map(run, & &1.size))}
      end)

    moof = build_moof(seq, placed)

    segments =
      Enum.flat_map(active, fn {_m, run} ->
        Enum.map(run, fn smp -> MdatSource.segment(mdats, smp.offset, smp.size) end)
      end)

    {moof, %Box{type: "mdat", size_mode: :compact, data: segments}}
  end

  defp build_moof(seq, trafs_spec) do
    mfhd = %Box{type: "mfhd", data: <<0::32, seq::32>>}
    trafs = Enum.map(trafs_spec, fn {meta, run, offset} -> build_traf(meta, run, offset) end)
    %Box{type: "moof", children: [mfhd | trafs]}
  end

  defp build_traf(meta, run, data_offset) do
    [first_sample | _] = run

    tfhd =
      TrackFragmentHeader.encode(%TrackFragmentHeader{
        track_id: meta.track_id,
        default_base_is_moof?: true
      })

    tfdt =
      TrackFragmentDecodeTime.encode(%TrackFragmentDecodeTime{
        version: 1,
        base_media_decode_time: first_sample.dts
      })

    # TrackRun.encode/1 picks v0/v1 from composition_offset presence; no version here.
    trun =
      TrackRun.encode(%TrackRun{
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
