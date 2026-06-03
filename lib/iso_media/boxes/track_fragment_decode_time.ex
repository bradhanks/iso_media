defmodule ISOMedia.Boxes.TrackFragmentDecodeTime do
  @moduledoc "Typed view of the `tfdt` Track Fragment Decode Time box."
  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :base_media_decode_time]

  @doc "Decode a `tfdt` box (v0 32-bit / v1 64-bit base time)."
  def decode(%Box{type: "tfdt", data: data}) do
    {version, _flags, rest} = FullBox.parse(data)
    %__MODULE__{version: version, base_media_decode_time: decode_time(version, rest)}
  end

  defp decode_time(0, <<t::32, _::binary>>), do: t
  defp decode_time(1, <<t::64, _::binary>>), do: t
end
