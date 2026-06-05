defmodule ISOMedia.Codec do
  @moduledoc """
  Read-only extraction of a track's codec + media metadata into `%ISOMedia.TrackInfo{}`.
  Slices the opaque `stsd` sample entry and `mdhd` tail directly (avc1 + mp4a); the core
  parser/Registry are untouched, so the byte-for-byte round-trip invariant is preserved.
  """
  import Bitwise

  alias ISOMedia.{Box, BoxPath, TrackInfo}
  alias ISOMedia.Boxes.{MediaHeader, TrackHeader}

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

  @doc "Decode a `trak`'s codec + media metadata into a `%ISOMedia.TrackInfo{}`."
  def info(%Box{type: "trak"} = trak) do
    track_id = TrackHeader.decode(BoxPath.dig(trak, ["tkhd"])).track_id

    mdhd =
      BoxPath.dig(trak, ~w(mdia mdhd)) || raise ArgumentError, "track_info: track missing mdhd"

    mh = MediaHeader.decode(mdhd)

    language =
      if byte_size(mh.rest) >= 2,
        do: decode_language(binary_part(mh.rest, 0, 2)),
        else: "und"

    stsd =
      BoxPath.dig(trak, ~w(mdia minf stbl stsd)) ||
        raise ArgumentError, "track_info: track missing stsd"

    <<_v::8, _f::24, _count::32, entry::binary>> = stsd.data
    <<_size::32, format::binary-size(4), _::binary>> = entry

    base = %TrackInfo{
      track_id: track_id,
      format: format,
      timescale: mh.timescale,
      duration: mh.duration,
      language: language
    }

    parse_entry(format, entry, base)
  end

  @doc "Build an `avc1.PPCCLL` codec string from an `avcC` payload."
  def avc1_codec(<<_config_version::8, profile::8, compat::8, level::8, _::binary>>) do
    "avc1." <> Base.encode16(<<profile, compat, level>>, case: :lower)
  end

  # VisualSampleEntry: width@32, height@34; child boxes (incl. avcC) start at offset 86.
  defp parse_entry("avc1", entry, base) do
    <<_::binary-size(32), width::16, height::16, _::binary>> = entry
    <<_::binary-size(86), children::binary>> = entry
    codec = avc1_codec(find_sub_box(children, "avcC"))
    %{base | type: :video, codec: codec, width: width, height: height}
  end

  # AudioSampleEntry: channelcount@24, samplerate@32 (16.16 fixed, integer part); esds@36.
  defp parse_entry("mp4a", entry, base) do
    <<_::binary-size(24), channels::16, _samplesize::16, _::16, _::16, sample_rate::16,
      _sr_low::16, _::binary>> = entry

    <<_::binary-size(36), children::binary>> = entry
    codec = mp4a_codec(find_sub_box(children, "esds"))
    %{base | type: :audio, codec: codec, sample_rate: sample_rate, channels: channels}
  end

  defp parse_entry(format, _entry, _base) do
    raise ArgumentError, "track_info: unsupported codec #{format}"
  end

  @doc """
  Build an `mp4a.<oti>.<aot>` codec string from an `esds` payload by walking the MPEG-4
  descriptors. Falls back to `"mp4a.40.2"` (AAC-LC) if the descriptor chain can't be walked.
  """
  def mp4a_codec(esds) do
    <<_v::8, _f::24, descriptors::binary>> = esds
    {oti, aot} = parse_es_descriptor(descriptors)
    "mp4a." <> Integer.to_string(oti, 16) <> "." <> Integer.to_string(aot)
  rescue
    _ -> "mp4a.40.2"
  end

  defp parse_es_descriptor(<<0x03, rest::binary>>) do
    {_len, body} = decode_expandable_length(rest)
    <<_es_id::16, _flags::8, dcd::binary>> = body
    parse_decoder_config(dcd)
  end

  defp parse_decoder_config(<<0x04, rest::binary>>) do
    {_len, body} = decode_expandable_length(rest)
    <<oti::8, _stream_type::8, _buffer::24, _max_br::32, _avg_br::32, dsi::binary>> = body
    {oti, parse_decoder_specific(dsi)}
  end

  defp parse_decoder_specific(<<0x05, rest::binary>>) do
    {_len, asc} = decode_expandable_length(rest)
    <<aot::5, _::bitstring>> = asc
    aot
  end
end
