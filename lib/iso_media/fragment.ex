defmodule ISOMedia.Fragment do
  @moduledoc """
  Repack a progressive MP4 into a single multiplexed fragmented tree
  `[ftyp, moov(+mvex), moof, mdat, …]`. Keyframe-aligned (a fragment starts on a sync
  sample so it is independently decodable), lossless (sample bytes via a Phase 8
  segment-list `mdat`), memory-safe. The inverse of `ISOMedia.Defragment`.
  """

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
end
