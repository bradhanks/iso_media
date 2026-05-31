defmodule ISOMedia.FullBox do
  @moduledoc """
  Helper for the `version` (1 byte) + `flags` (3 bytes) prefix that many
  ISOBMFF boxes (FullBoxes) carry before their payload.
  """

  @doc "Split a FullBox payload into `{version, flags, rest}`."
  def parse(<<version::8, flags::binary-size(3), rest::binary>>), do: {version, flags, rest}

  @doc "Build a FullBox payload iolist from version, flags, and the rest of the payload."
  def encode(version, <<_::24>> = flags, payload), do: [<<version::8>>, flags, payload]
end
