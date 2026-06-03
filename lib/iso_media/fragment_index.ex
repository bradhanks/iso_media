defmodule ISOMedia.FragmentIndex do
  @moduledoc """
  Indexes fragmented MP4 (`moof`/`traf`/`trun`) into the same `[%ISOMedia.Sample{}]`
  the progressive indexer produces. Offsets are resolved tree-locally (a single
  `Layout` walk stamps each `moof`'s position), and the cascade `trun → tfhd → trex`
  resolves per-sample duration/size/flags. `chunk_index` is a per-`trun` counter.
  """
  import Bitwise
  alias ISOMedia.Boxes.TrackRun

  @non_sync 0x00010000

  @doc "True when the tree is fragmented: has a `moov`/`mvex` and at least one `moof`."
  def fragmented?(boxes) when is_list(boxes) do
    moov = Enum.find(boxes, &(&1.type == "moov"))
    has_mvex = moov != nil and Enum.any?(moov.children, &(&1.type == "mvex"))
    has_moof = Enum.any?(boxes, &(&1.type == "moof"))
    has_mvex and has_moof
  end

  @doc "Index the fragmented track `track_id` into `[%ISOMedia.Sample{}]`."
  def samples(_boxes, _track_id) do
    raise ArgumentError, "FragmentIndex.samples/2 not yet implemented"
  end

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
