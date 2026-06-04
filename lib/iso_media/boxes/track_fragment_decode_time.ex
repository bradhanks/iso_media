defmodule ISOMedia.Boxes.TrackFragmentDecodeTime do
  @moduledoc "Typed view of the `tfdt` Track Fragment Decode Time box."
  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :base_media_decode_time]

  @type t :: %__MODULE__{
          version: 0 | 1,
          base_media_decode_time: non_neg_integer()
        }

  @doc "Decode a `tfdt` box (v0 32-bit / v1 64-bit base time)."
  @spec decode(ISOMedia.Box.t()) :: t()
  def decode(%Box{type: "tfdt", data: data}) do
    {version, _flags, rest} = FullBox.parse(data)
    %__MODULE__{version: version, base_media_decode_time: decode_time(version, rest)}
  end

  defp decode_time(0, <<t::32, _::binary>>), do: t
  defp decode_time(1, <<t::64, _::binary>>), do: t

  @doc "Encode a `%TrackFragmentDecodeTime{}` back into a `tfdt` box."
  @spec encode(t()) :: ISOMedia.Box.t()
  def encode(%__MODULE__{version: version, base_media_decode_time: t}) do
    body = encode_time(version, t)
    %Box{type: "tfdt", data: IO.iodata_to_binary(FullBox.encode(version, <<0, 0, 0>>, body))}
  end

  defp encode_time(0, t), do: <<t::32>>
  defp encode_time(1, t), do: <<t::64>>
end
