defmodule ISOMedia.FragmentIndex do
  @moduledoc """
  Indexes fragmented MP4 (`moof`/`traf`/`trun`) into the same `[%ISOMedia.Sample{}]`
  the progressive indexer produces. Offsets are resolved tree-locally (a single
  `Layout` walk stamps each `moof`'s position), and the cascade `trun → tfhd → trex`
  resolves per-sample duration/size/flags. `chunk_index` is a per-`trun` counter.
  """
  import Bitwise
  alias ISOMedia.{Box, Layout, Sample}
  alias ISOMedia.Boxes.{TrackExtends, TrackFragmentDecodeTime, TrackFragmentHeader, TrackRun}

  @non_sync 0x00010000

  @doc "True when the tree is fragmented: has a `moov`/`mvex` and at least one `moof`."
  def fragmented?(boxes) when is_list(boxes) do
    moov = Enum.find(boxes, &(&1.type == "moov"))
    has_mvex = moov != nil and Enum.any?(moov.children, &(&1.type == "mvex"))
    has_moof = Enum.any?(boxes, &(&1.type == "moof"))
    has_mvex and has_moof
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
    {recs, _end} =
      Enum.flat_map_reduce(boxes, 0, fn box, off ->
        rec = if box.type == "moof", do: [%{moof: box, offset: off}], else: []
        {rec, off + Layout.box_size(box)}
      end)

    recs
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
    truns = Enum.filter(traf.children, &(&1.type == "trun"))

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
    moov = Enum.find(boxes, &(&1.type == "moov")) || raise ArgumentError, "fMP4: no moov"
    mvex = Enum.find(moov.children, &(&1.type == "mvex")) || raise ArgumentError, "fMP4: no mvex"

    box =
      Enum.find(mvex.children, fn b ->
        b.type == "trex" and TrackExtends.decode(b).track_id == track_id
      end)

    if box,
      do: TrackExtends.decode(box),
      else: raise(ArgumentError, "fMP4: no trex for track #{track_id}")
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

  defp child(%Box{children: children}, type), do: Enum.find(children, &(&1.type == type))
  defp child!(box, type), do: child(box, type) || raise(ArgumentError, "fMP4: traf missing #{type}")

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
