defmodule ISOMedia.FullBox do
  @moduledoc """
  Helper for the `version` (1 byte) + `flags` (3 bytes) prefix that many
  ISOBMFF boxes (FullBoxes) carry before their payload.
  """

  @doc "Split a FullBox payload into `{version, flags, rest}`."
  def parse(<<version::8, flags::binary-size(3), rest::binary>>), do: {version, flags, rest}

  @doc "Build a FullBox payload iolist from version, flags, and the rest of the payload."
  def encode(version, <<_::24>> = flags, payload), do: [<<version::8>>, flags, payload]

  @doc "Like `encode/3` but returns a binary — the form every typed view's `encode/1` needs."
  def encode_data(version, flags, payload), do: IO.iodata_to_binary(encode(version, flags, payload))
end
