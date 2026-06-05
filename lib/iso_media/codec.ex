defmodule ISOMedia.Codec do
  @moduledoc """
  Read-only extraction of a track's codec + media metadata into `%ISOMedia.TrackInfo{}`.
  Slices the opaque `stsd` sample entry and `mdhd` tail directly (avc1 + mp4a); the core
  parser/Registry are untouched, so the byte-for-byte round-trip invariant is preserved.
  """
  import Bitwise

  @doc """
  Decode a packed 16-bit `mdhd` language field (1 pad bit + 3×5-bit, each `char - 0x60`)
  into an ISO-639-2/T 3-letter code. Falls back to `"und"` if any character is not `a`-`z`.
  """
  def decode_language(<<_pad::1, c1::5, c2::5, c3::5>>) do
    codes = [c1, c2, c3]

    if Enum.all?(codes, &(&1 in 1..26)) do
      List.to_string(Enum.map(codes, &(&1 + 0x60)))
    else
      "und"
    end
  end

  @doc """
  Decode an MPEG-4 expandable length (each byte's high bit is a continuation flag; the low
  7 bits accumulate). Returns `{length, remaining_binary}`.
  """
  def decode_expandable_length(binary, acc \\ 0)

  def decode_expandable_length(<<1::1, val::7, rest::binary>>, acc),
    do: decode_expandable_length(rest, bsl(acc, 7) + val)

  def decode_expandable_length(<<0::1, val::7, rest::binary>>, acc),
    do: {bsl(acc, 7) + val, rest}

  @doc "Return the payload of the first child box of `type` within a byte slice of boxes."
  def find_sub_box(<<size::32, type::binary-size(4), rest::binary>>, target)
      when size >= 8 and byte_size(rest) >= size - 8 do
    payload_len = size - 8
    <<payload::binary-size(payload_len), more::binary>> = rest
    if type == target, do: payload, else: find_sub_box(more, target)
  end

  def find_sub_box(_bin, target) do
    raise ArgumentError, "track_info: sub-box #{target} not found"
  end
end
