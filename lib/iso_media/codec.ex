defmodule ISOMedia.Codec do
  @moduledoc """
  Read-only extraction of a track's codec + media metadata into `%ISOMedia.TrackInfo{}`.
  Slices the opaque `stsd` sample entry and `mdhd` tail directly (avc1 + mp4a); the core
  parser/Registry are untouched, so the byte-for-byte round-trip invariant is preserved.
  """
  import Bitwise

  alias ISOMedia.{Box, BoxPath, TrackInfo}
  alias ISOMedia.Boxes.{MediaHeader, TrackHeader}

  @spec decode_language(<<_::16>>) :: String.t()
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

  @spec decode_expandable_length(binary(), non_neg_integer()) :: {non_neg_integer(), binary()}
  @doc """
  Decode an MPEG-4 expandable length (each byte's high bit is a continuation flag; the low
  7 bits accumulate). Returns `{length, remaining_binary}`.
  """
  def decode_expandable_length(binary, acc \\ 0)

  def decode_expandable_length(<<1::1, val::7, rest::binary>>, acc),
    do: decode_expandable_length(rest, bsl(acc, 7) + val)

  def decode_expandable_length(<<0::1, val::7, rest::binary>>, acc),
    do: {bsl(acc, 7) + val, rest}

  @spec find_sub_box(binary(), binary()) :: binary()
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

  @spec info(ISOMedia.Box.t()) :: ISOMedia.TrackInfo.t()
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

  @spec avc1_codec(binary()) :: String.t()
  @doc "Build an `avc1.PPCCLL` codec string from an `avcC` payload."
  def avc1_codec(<<_config_version::8, profile::8, compat::8, level::8, _::binary>>) do
    "avc1." <> Base.encode16(<<profile, compat, level>>, case: :lower)
  end

  @spec hvc1_codec(binary(), binary()) :: String.t()
  @doc """
  Build an RFC 6381 HEVC codec string (`hvc1.*` / `hev1.*`) from `fourcc` and an `hvcC`
  HEVCDecoderConfigurationRecord payload: profile (with profile-space prefix), the
  bit-reversed compatibility flags (uppercase hex, leading zeros dropped), `L`/`H` tier +
  level, and the constraint bytes (each formatted as two-digit uppercase hex, trailing-zero
  bytes omitted). Raises on a record shorter than 13 bytes.
  """
  def hvc1_codec(fourcc, <<
        _config_version::8,
        profile_space::2,
        tier_flag::1,
        profile_idc::5,
        compat_flags::32,
        c1::8,
        c2::8,
        c3::8,
        c4::8,
        c5::8,
        c6::8,
        level_idc::8,
        _rest::binary
      >>) do
    space =
      case profile_space do
        0 -> ""
        1 -> "A"
        2 -> "B"
        3 -> "C"
      end

    profile = "#{space}#{profile_idc}"
    compat = compat_flags |> reverse_32_bits() |> Integer.to_string(16)
    tier_level = "#{if tier_flag == 1, do: "H", else: "L"}#{level_idc}"

    constraints =
      [c1, c2, c3, c4, c5, c6]
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == 0))
      |> Enum.reverse()
      |> Enum.map(&String.pad_leading(Integer.to_string(&1, 16), 2, "0"))

    Enum.join([fourcc, profile, compat, tier_level | constraints], ".")
  end

  def hvc1_codec(_fourcc, _payload) do
    raise ArgumentError, "track_info: truncated or invalid hvcC payload"
  end

  # Reverse the 32 compatibility-flag bits via a 1-bit binary match (no Bitwise).
  defp reverse_32_bits(val) do
    <<b01::1, b02::1, b03::1, b04::1, b05::1, b06::1, b07::1, b08::1, b09::1, b10::1, b11::1,
      b12::1, b13::1, b14::1, b15::1, b16::1, b17::1, b18::1, b19::1, b20::1, b21::1, b22::1,
      b23::1, b24::1, b25::1, b26::1, b27::1, b28::1, b29::1, b30::1, b31::1, b32::1>> =
      <<val::32>>

    <<reversed::32>> =
      <<b32::1, b31::1, b30::1, b29::1, b28::1, b27::1, b26::1, b25::1, b24::1, b23::1, b22::1,
        b21::1, b20::1, b19::1, b18::1, b17::1, b16::1, b15::1, b14::1, b13::1, b12::1, b11::1,
        b10::1, b09::1, b08::1, b07::1, b06::1, b05::1, b04::1, b03::1, b02::1, b01::1>>

    reversed
  end

  # AudioSpecificConfig sampling-frequency index table (ISO/IEC 14496-3).
  @asc_freq %{
    0 => 96_000,
    1 => 88_200,
    2 => 64_000,
    3 => 48_000,
    4 => 44_100,
    5 => 32_000,
    6 => 24_000,
    7 => 22_050,
    8 => 16_000,
    9 => 12_000,
    10 => 11_025,
    11 => 8_000,
    12 => 7_350
  }

  @doc "Build an `mp4a.<oti>.<aot>` codec string from an `esds` payload (AAC-LC fallback)."
  @spec mp4a_codec(binary()) :: String.t()
  def mp4a_codec(esds) do
    {oti, aot, _rate} = parse_esds(esds)
    "mp4a." <> String.downcase(Integer.to_string(oti, 16)) <> "." <> Integer.to_string(aot)
  rescue
    _ -> "mp4a.40.2"
  end

  @doc "Sample rate (Hz) from an `esds` AudioSpecificConfig, or `fallback` if unavailable."
  @spec mp4a_sample_rate(binary(), pos_integer() | nil) :: pos_integer() | nil
  def mp4a_sample_rate(esds, fallback) do
    {_oti, _aot, rate} = parse_esds(esds)
    rate || fallback
  rescue
    _ -> fallback
  end

  defp parse_esds(<<_v::8, _f::24, descriptors::binary>>), do: parse_es_descriptor(descriptors)

  defp parse_es_descriptor(<<0x03, rest::binary>>) do
    {_len, body} = decode_expandable_length(rest)
    <<_es_id::16, flags::8, after_flags::binary>> = body
    after_flags |> skip_es_optional(flags) |> parse_decoder_config()
  end

  # ES_Descriptor optional fields (present per the flags byte): streamDependence (2),
  # URL (length-prefixed), OCR stream (2). Skipping them keeps the walk correct for
  # dependent / HE-AAC streams instead of falling through to the AAC-LC fallback.
  defp skip_es_optional(bin, flags) do
    bin
    |> skip_bytes(band(flags, 0x80) != 0, 2)
    |> skip_url(band(flags, 0x40) != 0)
    |> skip_bytes(band(flags, 0x20) != 0, 2)
  end

  defp skip_bytes(bin, false, _n), do: bin

  defp skip_bytes(bin, true, n) do
    <<_::binary-size(n), rest::binary>> = bin
    rest
  end

  defp skip_url(bin, false), do: bin

  defp skip_url(<<len::8, rest::binary>>, true) do
    <<_::binary-size(len), more::binary>> = rest
    more
  end

  defp parse_decoder_config(<<0x04, rest::binary>>) do
    {_len, body} = decode_expandable_length(rest)
    <<oti::8, _stream_type::8, _buffer::24, _max_br::32, _avg_br::32, dsi::binary>> = body
    {aot, rate} = parse_decoder_specific(dsi)
    {oti, aot, rate}
  end

  defp parse_decoder_specific(<<0x05, rest::binary>>) do
    {_len, asc} = decode_expandable_length(rest)
    <<aot::5, freq_index::4, _::bitstring>> = asc
    {aot, asc_rate(freq_index, asc)}
  end

  defp asc_rate(15, asc) do
    <<_::9, explicit::24, _::bitstring>> = asc
    explicit
  end

  defp asc_rate(index, _asc), do: Map.get(@asc_freq, index)

  # VisualSampleEntry: width@32, height@34; child boxes (incl. avcC) start at offset 86.
  defp parse_entry("avc1", entry, base) when byte_size(entry) >= 86 do
    <<_::binary-size(32), width::16, height::16, _::binary>> = entry
    <<_::binary-size(86), children::binary>> = entry
    codec = avc1_codec(find_sub_box(children, "avcC"))
    %{base | type: :video, codec: codec, width: width, height: height}
  end

  # AudioSampleEntry: channelcount@24, samplerate@32 (16.16; integer part is a fallback);
  # esds@36. The authoritative sample rate is the esds AudioSpecificConfig.
  defp parse_entry("mp4a", entry, base) when byte_size(entry) >= 36 do
    <<_::binary-size(24), channels::16, _samplesize::16, _::16, _::16, sr_fallback::16,
      _sr_low::16, _::binary>> = entry

    <<_::binary-size(36), children::binary>> = entry
    esds = find_sub_box(children, "esds")

    %{
      base
      | type: :audio,
        codec: mp4a_codec(esds),
        sample_rate: mp4a_sample_rate(esds, sr_fallback),
        channels: channels
    }
  end

  # HEVC VisualSampleEntry: same layout as avc1 (width@32, height@34, child boxes@86).
  defp parse_entry(fmt, entry, base) when fmt in ["hvc1", "hev1"] and byte_size(entry) >= 86 do
    <<_::binary-size(32), width::16, height::16, _::binary>> = entry
    <<_::binary-size(86), children::binary>> = entry
    codec = hvc1_codec(fmt, find_sub_box(children, "hvcC"))
    %{base | type: :video, codec: codec, width: width, height: height}
  end

  defp parse_entry(format, entry, _base) when format in ["avc1", "mp4a", "hvc1", "hev1"] do
    raise ArgumentError,
          "track_info: truncated #{format} sample entry (#{byte_size(entry)} bytes)"
  end

  defp parse_entry(format, _entry, _base) do
    raise ArgumentError, "track_info: unsupported codec #{format}"
  end
end
