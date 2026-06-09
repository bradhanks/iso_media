defmodule ISOMedia.Boxes.ChunkOffset do
  @moduledoc """
  Typed view of the `stco` (32-bit) and `co64` (64-bit) Chunk Offset Boxes.
  `kind` is `:stco` or `:co64`; `offsets` is a list of absolute file offsets.
  """

  alias ISOMedia.{Box, FullBox}

  @uint32_max 0xFFFFFFFF

  defstruct [:kind, :version, :flags, :offsets]

  @type t :: %__MODULE__{
          kind: :stco | :co64,
          version: non_neg_integer(),
          flags: <<_::24>>,
          offsets: [non_neg_integer()]
        }

  @doc """
  Which chunk-offset table addresses a maximum offset of `max`: `:co64` once an offset
  would exceed the 32-bit `stco` field (2^32 − 1), otherwise `:stco`. The one home for
  the stco↔co64 choice, used by the progressive builders (`Trim`/`Extract`/`ProgressiveBuild`).
  """
  @spec kind_for(non_neg_integer()) :: :stco | :co64
  def kind_for(max) when is_integer(max) and max >= 0 do
    if max > @uint32_max, do: :co64, else: :stco
  end

  @doc "Decode a `stco`/`co64` box into a `%ChunkOffset{}`."
  def decode(%Box{type: "stco", data: data}), do: do_decode(:stco, data, 32)
  def decode(%Box{type: "co64", data: data}), do: do_decode(:co64, data, 64)

  defp do_decode(kind, data, width) do
    {version, flags, <<_count::32, entries::binary>>} = FullBox.parse(data)
    offsets = for <<o::size(width) <- entries>>, do: o
    %__MODULE__{kind: kind, version: version, flags: flags, offsets: offsets}
  end

  @doc "Encode a `%ChunkOffset{}` back into a `stco`/`co64` box."
  def encode(%__MODULE__{kind: :stco} = co), do: do_encode(co, "stco", 32)
  def encode(%__MODULE__{kind: :co64} = co), do: do_encode(co, "co64", 64)

  defp do_encode(%__MODULE__{version: v, flags: f, offsets: offs}, type, width) do
    entries = for o <- offs, into: <<>>, do: <<o::size(width)>>
    body = [<<length(offs)::32>>, entries]
    %Box{type: type, data: FullBox.encode_data(v, f, body)}
  end
end
