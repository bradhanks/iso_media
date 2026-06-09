defmodule ISOMedia.FragmentIndex do
  @moduledoc """
  Indexes fragmented MP4 (`moof`/`traf`/`trun`) into the same `[%ISOMedia.Sample{}]`
  the progressive indexer produces. Offsets are resolved tree-locally (a single
  `Layout` walk stamps each `moof`'s position), and the cascade `trun → tfhd → trex`
  resolves per-sample duration/size/flags. `chunk_index` is a per-`trun` counter.
  """
  import Bitwise
  alias ISOMedia.{Box, BoxPath, Extract, Layout, Payload, Sample, Trak}

  alias ISOMedia.Boxes.{
    Handler,
    TrackExtends,
    TrackFragmentDecodeTime,
    TrackFragmentHeader,
    TrackRun
  }

  @non_sync 0x00010000

  @doc "True when the tree is fragmented: has a `moov`/`mvex` and at least one `moof`."
  def fragmented?(boxes) when is_list(boxes) do
    moov = Box.child(boxes, "moov")
    has_mvex = moov != nil and Box.child(moov.children, "mvex") != nil
    has_moof = Box.child(boxes, "moof") != nil
    has_mvex and has_moof
  end

  @doc """
  Per-`moof` spans for the fragmented tree `boxes`, in tree order:
  `[%{duration_ts, timescale, bytes}]`. For each `moof` the video `traf` is preferred (else
  the first `traf`); its `trun` sample durations are summed (via the cascade) for
  `duration_ts`, `timescale` is that track's `mdhd` timescale, and `bytes` is the sibling
  `mdat`'s payload size. Shared by HLS/DASH manifest generation.
  """
  @spec fragment_spans([Box.t()]) :: [
          %{duration_ts: non_neg_integer(), timescale: pos_integer(), bytes: non_neg_integer()}
        ]
  def fragment_spans(boxes) do
    video_tid = video_track_id(boxes)
    moofs = Box.children(boxes, "moof")
    mdats = Box.children(boxes, "mdat")

    moofs
    |> Enum.zip(mdats)
    |> Enum.map(fn {moof, mdat} ->
      traf = (video_tid && traf_for(moof, video_tid)) || first_traf(moof)
      tfhd = TrackFragmentHeader.decode(child!(traf, "tfhd"))
      defaults = defaults(tfhd, trex_for!(boxes, tfhd.track_id))

      duration_ts =
        traf.children
        |> Box.children("trun")
        |> Enum.flat_map(fn t -> resolve_run(TrackRun.decode(t), defaults) end)
        |> Enum.map(& &1.duration)
        |> Enum.sum()

      %{
        duration_ts: duration_ts,
        timescale: track_timescale(boxes, tfhd.track_id),
        bytes: Payload.size(mdat.data)
      }
    end)
  end

  @doc "Index the fragmented track `track_id` into `[%ISOMedia.Sample{}]`."
  def samples(boxes, track_id) do
    trex = trex_for!(boxes, track_id)

    {rev, _sidx, _cidx} =
      boxes
      |> moof_layout()
      |> Enum.reduce({[], 0, 0}, fn %{moof: moof, offset: moof_off}, acc ->
        case traf_for(moof, track_id) do
          nil -> acc
          traf -> index_traf(traf, moof_off, trex, acc)
        end
      end)

    Enum.reverse(rev)
  end

  # One %{moof, offset} per moof, offset stamped by the tree-local Layout walk.
  defp moof_layout(boxes) do
    boxes
    |> Layout.top_level_layout()
    |> Enum.filter(&(&1.box.type == "moof"))
    |> Enum.map(fn %{box: moof, offset: offset} -> %{moof: moof, offset: offset} end)
  end

  defp index_traf(traf, moof_off, trex, {acc, sidx, cidx}) do
    tfhd = TrackFragmentHeader.decode(child!(traf, "tfhd"))

    unless tfhd.default_base_is_moof? do
      raise ArgumentError,
            "fMP4: track #{tfhd.track_id} fragment does not set default-base-is-moof " <>
              "(unsupported addressing)"
    end

    check_unencrypted!(traf)

    base_dts =
      case child(traf, "tfdt") do
        nil -> 0
        box -> TrackFragmentDecodeTime.decode(box).base_media_decode_time
      end

    defaults = defaults(tfhd, trex)
    truns = Box.children(traf.children, "trun")

    {acc, sidx, cidx, _dts} =
      Enum.reduce(truns, {acc, sidx, cidx, base_dts}, fn trun_box, {acc, si, ci, dts} ->
        trun = TrackRun.decode(trun_box)
        ci = ci + 1
        run_start = moof_off + (trun.data_offset || 0)

        {acc, si, _off, dts} =
          trun
          |> resolve_run(defaults)
          |> Enum.reduce({acc, si, run_start, dts}, fn r, {acc, si, off, dts} ->
            si = si + 1

            sample = %Sample{
              index: si,
              chunk_index: ci,
              dts: dts,
              duration: r.duration,
              pts: dts + r.composition_offset,
              size: r.size,
              offset: off,
              sync?: r.sync?
            }

            {[sample | acc], si, off + r.size, dts + r.duration}
          end)

        {acc, si, ci, dts}
      end)

    {acc, sidx, cidx}
  end

  defp defaults(tfhd, trex) do
    %{
      duration: tfhd.default_sample_duration || trex.default_sample_duration,
      size: tfhd.default_sample_size || trex.default_sample_size,
      flags: tfhd.default_sample_flags || trex.default_sample_flags
    }
  end

  defp trex_for!(boxes, track_id) do
    moov = Box.child!(boxes, "moov", "fMP4")
    mvex = Box.child!(moov.children, "mvex", "fMP4")

    mvex.children
    |> Box.children("trex")
    |> Enum.map(&TrackExtends.decode/1)
    |> Enum.find(&(&1.track_id == track_id)) ||
      raise(ArgumentError, "fMP4: no trex for track #{track_id}")
  end

  defp traf_for(moof, track_id) do
    Enum.find(moof.children, fn b ->
      b.type == "traf" and
        case child(b, "tfhd") do
          nil -> false
          tfhd -> TrackFragmentHeader.decode(tfhd).track_id == track_id
        end
    end)
  end

  defp check_unencrypted!(traf) do
    if Enum.any?(traf.children, &(&1.type in ~w(senc saiz saio))) do
      raise ArgumentError, "fMP4: encrypted fragments (senc/saiz/saio) are not supported"
    end
  end

  defp first_traf(moof), do: Box.child(moof.children, "traf")

  defp video_track_id(boxes) do
    moov = Box.child(boxes, "moov")

    moov.children
    |> Box.children("trak")
    |> Enum.find_value(fn trak ->
      if Handler.decode(BoxPath.dig(trak, ~w(mdia hdlr))).handler_type == "vide" do
        Trak.id(trak)
      end
    end)
  end

  defp track_timescale(boxes, track_id) do
    Trak.timescale(Extract.find_trak(boxes, track_id))
  end

  defp child(%Box{children: children}, type), do: Box.child(children, type)

  defp child!(box, type),
    do: child(box, type) || raise(ArgumentError, "fMP4: traf missing #{type}")

  @doc """
  Resolve one `trun`'s per-sample fields against merged `defaults`
  (`%{duration, size, flags}`, already tfhd-over-trex). Returns
  `[%{duration, size, composition_offset, sync?}]`. `sync?` negates the
  `sample_is_non_sync_sample` bit.
  """
  def resolve_run(%TrackRun{} = trun, defaults) do
    trun.samples
    |> Enum.with_index()
    |> Enum.map(fn {s, i} ->
      flags = s.flags || first_flags(trun, i) || defaults.flags || 0

      %{
        duration: s.duration || defaults.duration || 0,
        size: s.size || defaults.size || 0,
        composition_offset: s.composition_offset || 0,
        sync?: (flags &&& @non_sync) == 0
      }
    end)
  end

  defp first_flags(%TrackRun{first_sample_flags: f}, 0), do: f
  defp first_flags(_trun, _i), do: nil
end
