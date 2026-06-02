defmodule ISOMedia.Sample do
  @moduledoc """
  One media sample, decoded from a track's sample tables.

  `index`/`chunk_index` are 1-based (matching ISOBMFF numbering). `dts`/`pts` are in
  the track's `mdhd` timescale (`pts == dts` when there is no `ctts`). `offset` is the
  sample's absolute byte position in the file. `sync?` is the keyframe flag (true for
  every sample when the track has no `stss`).
  """

  defstruct [:index, :chunk_index, :dts, :duration, :pts, :size, :offset, :sync?]

  @type t :: %__MODULE__{
          index: pos_integer(),
          chunk_index: pos_integer(),
          dts: non_neg_integer(),
          duration: non_neg_integer(),
          pts: integer(),
          size: non_neg_integer(),
          offset: non_neg_integer(),
          sync?: boolean()
        }
end
