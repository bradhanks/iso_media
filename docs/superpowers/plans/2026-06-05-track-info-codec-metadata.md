# Track Codec & Media Metadata (TrackInfo) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ISOMedia.track_info(boxes, track_id)` → `%ISOMedia.TrackInfo{}` with the RFC 6381 codec string and media metadata, parsed directly from the opaque `stsd`/`mdhd` bytes (avc1 + mp4a) without touching the core parser.

**Architecture:** A read-only `ISOMedia.Codec` module slices the `stsd` first sample entry and the `mdhd` tail in place: avc1 → `avcC` profile/compat/level; mp4a → `esds` MPEG-4 descriptors (object-type) via an expandable-length decoder; language from the packed `mdhd` bits. Returns a typed `%TrackInfo{}`. The Registry/parser are untouched, so the byte-for-byte round-trip invariant is preserved.

**Tech Stack:** Elixir, ExUnit, `Bitwise`, `Base.encode16`. Reuses `MediaHeader`/`TrackHeader`/`Extract.find_trak`. No new deps.

---

## File structure

**Created:**
- `lib/iso_media/track_info.ex` — the `%TrackInfo{}` struct
- `lib/iso_media/codec.ex` — `info/1` + the byte-slicing helpers (`decode_language/1`, `decode_expandable_length/2`, `find_sub_box/2`)
- `test/iso_media/codec_test.exs` — helper units + real-fixture + raise tests

**Modified:**
- `lib/iso_media.ex` — `track_info/2` delegator
- `CLAUDE.md` — architecture bullet

Pinned fixture values (`test/fixtures/sample_av.mp4`): video track → `avc1`, 128×96, `avc1.64000a`, ts 10240, lang `und`; audio track → `mp4a`, 1ch, 44100Hz, `mp4a.40.2`, ts 44100, lang `und`. The video `track_id` is the `vide`-handler track, audio is `soun` — derive them via `track_ids/1` + handler, do not hardcode the numeric ids.

---

## Task 1: Byte-slicing helpers (language, expandable length, sub-box scan)

**Files:**
- Create: `lib/iso_media/codec.ex`
- Test: `test/iso_media/codec_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/codec_test.exs`:

```elixir
defmodule ISOMedia.CodecTest do
  use ExUnit.Case
  alias ISOMedia.Codec

  describe "decode_language/1" do
    test "decodes packed ISO-639-2/T codes" do
      assert Codec.decode_language(<<0x55C4::16>>) == "und"
      assert Codec.decode_language(<<0x15C7::16>>) == "eng"
    end

    test "defaults to und on zero/invalid codes" do
      assert Codec.decode_language(<<0::16>>) == "und"
      # a 5-bit value of 0 maps to a backtick — must fall back, not emit junk
      assert Codec.decode_language(<<0x0042::16>>) == "und"
    end
  end

  describe "decode_expandable_length/1" do
    test "single-byte length" do
      assert Codec.decode_expandable_length(<<0x25, 0xFF>>) == {37, <<0xFF>>}
    end

    test "multi-byte (continuation) length, e.g. the ffmpeg 0x80 0x80 0x80 LL form" do
      assert Codec.decode_expandable_length(<<0x80, 0x80, 0x80, 0x25>>) == {37, <<>>}
    end
  end

  describe "find_sub_box/2" do
    test "returns the payload of the first matching sub-box" do
      bin = <<10::32, "free", 0, 0, 12::32, "avcC", 9, 9, 9, 9>>
      assert Codec.find_sub_box(bin, "avcC") == <<9, 9, 9, 9>>
    end

    test "raises when the sub-box is absent" do
      assert_raise ArgumentError, fn -> Codec.find_sub_box(<<8::32, "free">>, "avcC") end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/codec_test.exs`
Expected: FAIL — `ISOMedia.Codec` does not exist.

- [ ] **Step 3: Create `ISOMedia.Codec` with the helpers**

Create `lib/iso_media/codec.ex`:

```elixir
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/codec_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/codec.ex test/iso_media/codec_test.exs
git commit -m "feat: Codec byte-slicing helpers (language, expandable length, sub-box scan)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `TrackInfo` struct + video (avc1) extraction + `track_info/2`

**Files:**
- Create: `lib/iso_media/track_info.ex`
- Modify: `lib/iso_media/codec.ex`, `lib/iso_media.ex`
- Test: `test/iso_media/codec_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/iso_media/codec_test.exs`:

```elixir
  describe "track_info/2 — video (avc1)" do
    defp video_tid(boxes) do
      Enum.find(ISOMedia.track_ids(boxes), fn tid ->
        trak = ISOMedia.Extract.find_trak(boxes, tid)
        ISOMedia.Boxes.Handler.decode(ISOMedia.BoxPath.dig(trak, ~w(mdia hdlr))).handler_type == "vide"
      end)
    end

    test "extracts avc1 codec string, dimensions, and media metadata" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
      info = ISOMedia.track_info(boxes, video_tid(boxes))

      assert info.type == :video
      assert info.format == "avc1"
      assert info.codec == "avc1.64000a"
      assert info.width == 128
      assert info.height == 96
      assert info.timescale == 10240
      assert info.language == "und"
      assert info.sample_rate == nil and info.channels == nil
    end

    test "derives the avc1 codec string from avcC profile/compat/level bytes" do
      # avcC payload: configurationVersion=1, profile=0x64, compat=0x00, level=0x1f, then more
      avcc = <<1, 0x64, 0x00, 0x1F, 0xFF, 0xE1>>
      assert ISOMedia.Codec.avc1_codec(avcc) == "avc1.64001f"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/codec_test.exs`
Expected: FAIL — `ISOMedia.track_info/2` and `Codec.avc1_codec/1` undefined.

- [ ] **Step 3: Create the struct, the video path, and the delegator**

Create `lib/iso_media/track_info.ex`:

```elixir
defmodule ISOMedia.TrackInfo do
  @moduledoc "Decoded codec + media metadata for one track. See `ISOMedia.track_info/2`."

  @type type :: :video | :audio

  @type t :: %__MODULE__{
          track_id: pos_integer(),
          type: type(),
          format: String.t(),
          codec: String.t(),
          timescale: pos_integer(),
          duration: non_neg_integer(),
          language: String.t(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          sample_rate: pos_integer() | nil,
          channels: pos_integer() | nil
        }

  defstruct [
    :track_id,
    :type,
    :format,
    :codec,
    :timescale,
    :duration,
    :language,
    :width,
    :height,
    :sample_rate,
    :channels
  ]
end
```

In `lib/iso_media/codec.ex`, add the aliases under `import Bitwise`:

```elixir
  alias ISOMedia.{Box, BoxPath, TrackInfo}
  alias ISOMedia.Boxes.{MediaHeader, TrackHeader}
```

and add `info/1`, `avc1_codec/1`, and the entry dispatch (place after the helpers):

```elixir
  @doc "Decode a `trak`'s codec + media metadata into a `%ISOMedia.TrackInfo{}`."
  def info(%Box{type: "trak"} = trak) do
    track_id = TrackHeader.decode(BoxPath.dig(trak, ["tkhd"])).track_id
    mdhd = BoxPath.dig(trak, ~w(mdia mdhd)) || raise ArgumentError, "track_info: track missing mdhd"
    mh = MediaHeader.decode(mdhd)

    language =
      if byte_size(mh.rest) >= 2,
        do: decode_language(binary_part(mh.rest, 0, 2)),
        else: "und"

    stsd = BoxPath.dig(trak, ~w(mdia minf stbl stsd)) || raise ArgumentError, "track_info: track missing stsd"
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

  defp parse_entry(format, _entry, _base) do
    raise ArgumentError, "track_info: unsupported codec #{format}"
  end
```

In `lib/iso_media.ex`, add after the `write_segments/3` delegator:

```elixir
  @doc "Decode a track's codec + media metadata into `%ISOMedia.TrackInfo{}`. See `ISOMedia.Codec.info/1`."
  @spec track_info(tree(), pos_integer()) :: ISOMedia.TrackInfo.t()
  def track_info(boxes, track_id) do
    case ISOMedia.Extract.find_trak(boxes, track_id) do
      nil -> raise ArgumentError, "track_info: no track with track_id #{track_id}"
      trak -> ISOMedia.Codec.info(trak)
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/codec_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/track_info.ex lib/iso_media/codec.ex lib/iso_media.ex test/iso_media/codec_test.exs
git commit -m "feat: TrackInfo struct + avc1 video metadata + ISOMedia.track_info/2

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Audio (mp4a) extraction via esds

**Files:**
- Modify: `lib/iso_media/codec.ex`
- Test: `test/iso_media/codec_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/iso_media/codec_test.exs`:

```elixir
  describe "track_info/2 — audio (mp4a)" do
    defp audio_tid(boxes) do
      Enum.find(ISOMedia.track_ids(boxes), fn tid ->
        trak = ISOMedia.Extract.find_trak(boxes, tid)
        ISOMedia.Boxes.Handler.decode(ISOMedia.BoxPath.dig(trak, ~w(mdia hdlr))).handler_type == "soun"
      end)
    end

    test "extracts mp4a codec string, sample rate, channels" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
      info = ISOMedia.track_info(boxes, audio_tid(boxes))

      assert info.type == :audio
      assert info.format == "mp4a"
      assert info.codec == "mp4a.40.2"
      assert info.sample_rate == 44100
      assert info.channels == 1
      assert info.timescale == 44100
      assert info.width == nil and info.height == nil
    end

    test "derives mp4a.40.2 from an AAC-LC esds descriptor chain" do
      # esds: FullBox(4) + ES_Descriptor(0x03) -> DecoderConfig(0x04, oti 0x40)
      #       -> DecoderSpecificInfo(0x05, AudioSpecificConfig 0x12 -> aot 2)
      dsi = <<0x05, 0x02, 0x12, 0x08>>
      dcd = <<0x04, 0x0D, 0x40, 0x15, 0::24, 0::32, 0::32>> <> dsi
      es = <<0x03, byte_size(<<0::16, 0::8>> <> dcd), 0::16, 0::8>> <> dcd
      esds = <<0::32>> <> es
      assert ISOMedia.Codec.mp4a_codec(esds) == "mp4a.40.2"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/codec_test.exs`
Expected: FAIL — the `"mp4a"` clause and `Codec.mp4a_codec/1` don't exist (the unsupported-format clause raises).

- [ ] **Step 3: Add the audio path + esds descriptor walk**

In `lib/iso_media/codec.ex`, add a `parse_entry("mp4a", …)` clause BEFORE the catch-all `parse_entry(format, …)` clause, and add the esds parsing functions:

```elixir
  # AudioSampleEntry: channelcount@24, samplerate@32 (16.16 fixed, integer part); esds@36.
  defp parse_entry("mp4a", entry, base) do
    <<_::binary-size(24), channels::16, _samplesize::16, _::16, _::16, sample_rate::16,
      _sr_low::16, _::binary>> = entry

    <<_::binary-size(36), children::binary>> = entry
    codec = mp4a_codec(find_sub_box(children, "esds"))
    %{base | type: :audio, codec: codec, sample_rate: sample_rate, channels: channels}
  end
```

and (after `avc1_codec/1`):

```elixir
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/codec_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/codec.ex test/iso_media/codec_test.exs
git commit -m "feat: mp4a audio metadata via esds descriptor walk (codec, sample rate, channels)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Integration — unsupported/missing raises, round-trip guard, docs

**Files:**
- Modify: `CLAUDE.md`
- Test: `test/iso_media/codec_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/iso_media/codec_test.exs`:

```elixir
  describe "track_info/2 — errors and invariants" do
    test "raises on an unsupported codec format" do
      # Minimal hand-built trak: info/1 needs tkhd (track_id), mdia/mdhd, mdia/minf/stbl/stsd.
      tkhd = %ISOMedia.Box{type: "tkhd", data: <<0::8, 0::24, 0::32, 0::32, 1::32, 0::32, 0::32, 0::binary-size(60)>>}
      mdhd = %ISOMedia.Box{type: "mdhd", data: <<0::8, 0::24, 0::32, 0::32, 1000::32, 0::32, 0x55C4::16, 0::16>>}
      stsd = %ISOMedia.Box{type: "stsd", data: <<0::8, 0::24, 1::32, 16::32, "hvc1", 0::64>>}
      stbl = %ISOMedia.Box{type: "stbl", children: [stsd]}
      minf = %ISOMedia.Box{type: "minf", children: [stbl]}
      mdia = %ISOMedia.Box{type: "mdia", children: [mdhd, minf]}
      trak = %ISOMedia.Box{type: "trak", children: [tkhd, mdia]}
      moov = %ISOMedia.Box{type: "moov", children: [trak]}

      assert_raise ArgumentError, ~r/unsupported codec hvc1/, fn ->
        ISOMedia.track_info([moov], 1)
      end
    end

    test "raises when the track_id is absent" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
      assert_raise ArgumentError, ~r/no track with track_id 999/, fn ->
        ISOMedia.track_info(boxes, 999)
      end
    end

    test "track_info does not disturb the byte-for-byte round trip" do
      bin = File.read!("test/fixtures/sample_av.mp4")
      {:ok, boxes} = ISOMedia.parse(bin)
      _ = ISOMedia.track_info(boxes, hd(ISOMedia.track_ids(boxes)))
      assert ISOMedia.serialize(boxes) == bin
    end
  end
```

- [ ] **Step 2: Run test to verify it fails (or passes)**

Run: `mix test test/iso_media/codec_test.exs`
Expected: these should PASS given Tasks 1-3 (the behavior already exists). If the synthetic `trak` in the unsupported-codec test doesn't assemble cleanly (e.g. `TrackHeader.encode` rest-size mismatch), fix the synthetic box construction — do NOT change library code. If `track_info` raises for the wrong reason, debug with `superpowers:systematic-debugging`.

- [ ] **Step 3: Confirm green; no library change expected**

Run: `mix test test/iso_media/codec_test.exs`
Expected: PASS. (This task is verification + docs; Tasks 1-3 implemented the behavior. If a test exposes a real gap, fix the minimal library cause.)

- [ ] **Step 4: Update CLAUDE.md, full sweep, commit**

Add an `ISOMedia.Codec` / `TrackInfo` bullet to `CLAUDE.md`'s architecture list (near the typed-view boxes): `ISOMedia.Codec.info/1` (reached via `ISOMedia.track_info/2`) decodes a track's codec + media metadata into `%ISOMedia.TrackInfo{}` (RFC 6381 codec string for `avc1`/`mp4a`, dimensions / sample-rate+channels, timescale/duration/language) by slicing the opaque `stsd`/`mdhd` directly — the core parser/Registry are untouched, preserving the round-trip invariant; unsupported codecs raise.

Run: `mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: 0 failures, format clean, no warnings.

```bash
git add test/iso_media/codec_test.exs CLAUDE.md
git commit -m "test: track_info raises (unsupported/missing) + round-trip guard; docs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Full guarantee sweep**

Run: `mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: 0 failures, format clean, no warnings.

---

## Spec coverage check

- `%TrackInfo{}` struct (fields, `type :: :video | :audio`) → Task 2.
- `track_info/2` delegator + `Codec.info/1` (mdhd timescale/duration/language; stsd dispatch) → Task 2.
- Language decode (`und` fallback) → Task 1.
- avc1 codec string + width/height → Task 2.
- mp4a codec string (esds walk, expandable length) + sample_rate/channels → Tasks 1+3.
- Targeted parsing, parser/Registry untouched (round-trip guard) → Task 4.
- Raises (unsupported format, missing track) → Tasks 2+4.
- Deferred (HEVC/AV1/subtitle, bitrate, manifests, multi-entry stsd) → not implemented, by design.
```
