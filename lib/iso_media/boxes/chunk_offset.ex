defmodule ISOMedia.Boxes.ChunkOffset do
  @moduledoc """
  Typed view of the `stco` (32-bit) and `co64` (64-bit) Chunk Offset Boxes.
  `kind` is `:stco` or `:co64`; `offsets` is a list of absolute file offsets.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:kind, :version, :flags, :offsets]

  @type t :: %__MODULE__{
          kind: :stco | :co64,
          version: non_neg_integer(),
          flags: <<_::24>>,
          offsets: [non_neg_integer()]
        }

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
    %Box{type: type, data: IO.iodata_to_binary(FullBox.encode(v, f, body))}
  end
end
