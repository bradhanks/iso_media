defmodule ISOMedia.FragmentIndex do
  @moduledoc """
  Indexes fragmented MP4 (`moof`/`traf`/`trun`) into the same `[%ISOMedia.Sample{}]`
  the progressive indexer produces. Offsets are resolved tree-locally (a single
  `Layout` walk stamps each `moof`'s position), and the cascade `trun → tfhd → trex`
  resolves per-sample duration/size/flags. `chunk_index` is a per-`trun` counter.
  """

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
end
