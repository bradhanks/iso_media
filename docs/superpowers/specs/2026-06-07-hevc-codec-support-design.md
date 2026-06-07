# Design: HEVC (H.265) codec support in `track_info/2`

**Date:** 2026-06-07
**Status:** Draft (design phase)
**Builds on:** Phase 12 (TrackInfo codec metadata, `avc1`/`mp4a`).

## Goal

Decode HEVC (`hvc1` / `hev1`) video sample entries in `ISOMedia.Codec`, producing the RFC 6381
codec string (e.g. `hvc1.1.6.L93.B0`) plus `width`/`height`, so `track_info/2` works on HEVC
tracks. This unblocks the whole codec-dependent surface end-to-end for HEVC content:
`hls_master_playlist/2`, `write_hls/3`, `dash_manifest/2`, `write_dash/3` (all of which build a
`CODECS=`/`codecs=` string via `ISOMedia.Manifest` → `track_info/2`, and currently raise on
`hvc1`).

This is **roadmap item #1**. Scope is **codec-string only** — mirror `avc1` exactly; no new
`%TrackInfo{}` fields. The core parser/Registry are untouched (the targeted slice of the opaque
`stsd` preserves the byte-for-byte round-trip invariant).

## Decisions (from brainstorming)

- **Mirror the `avc1` path, don't add a module.** Two new `parse_entry/3` clauses in
  `lib/iso_media/codec.ex` + one `hvc1_codec/2` helper. A separate HEVC module is ceremony for
  one codec string; cohesion with the existing `avc1`/`mp4a` handlers wins.
- **`hvc1` and `hev1` both in scope.** Identical track layout — both store the parameter sets
  in an `hvcC` sub-box inside the sample entry (`hev1` additionally *permits* in-band parameter
  sets in the media samples, which does not affect `hvcC` parsing). The codec string is prefixed
  with the **actual fourcc**, so `hev1` files yield `hev1.*`. Free ride.
- **Uppercase hex for HEVC.** `hvc1.1.6.L93.B0` — uppercase tier (`L`/`H`) and uppercase hex
  parts, matching the Apple/Chromium/MP4Box convention (engines are pedantic about this).
  `avc1` stays lowercase (`avc1.64001f`); different codec, different de-facto standard — not a
  contradiction.
- **Codec-string only.** No `profile`/`tier`/`level` fields added to `%TrackInfo{}` (YAGNI;
  manifests need only the string). `type: :video`, `format: "hvc1"`/`"hev1"`, `width`, `height`.
- **Raise on a bad `hvcC` (like `avc1`, unlike `mp4a`).** There is no sensible default HEVC
  codec string, so a missing or truncated (< 13-byte) `hvcC` raises `ArgumentError`.

## The `hvcC` byte layout

The first 13 bytes of the `HEVCDecoderConfigurationRecord` (ISO/IEC 14496-15 §8.3.3.1) carry
everything the codec string needs:

```
byte 0      configurationVersion
byte 1      general_profile_space (2) | general_tier_flag (1) | general_profile_idc (5)
bytes 2–5   general_profile_compatibility_flags (32-bit)
bytes 6–11  general_constraint_indicator_flags (48-bit, 6 bytes)
byte 12     general_level_idc
bytes 13+   numTemporalLayers/lengthSizeMinusOne/parameter-set arrays — ignored
```

## The RFC 6381 codec string

`"<fourcc>."` followed by these dot-joined parts:

1. **profile** — `general_profile_space` as a prefix (`""`/`"A"`/`"B"`/`"C"` for `0`/`1`/`2`/`3`)
   concatenated with `general_profile_idc` in decimal → e.g. `1`.
2. **compatibility** — the 32 `general_profile_compatibility_flags` in **reverse bit order**,
   then uppercase hexadecimal with leading zeros omitted → e.g. Main's `0x60000000` reverses to
   `0x6` → `6`.
3. **tier + level** — `general_tier_flag` as `L` (0) / `H` (1) concatenated with
   `general_level_idc` in decimal → e.g. `L93` (level_idc 93 = level 3.1).
4. **constraints** — the 6 `general_constraint_indicator_flags` bytes with **trailing-zero bytes
   omitted**, each formatted as two uppercase hex digits (`%02X`), dot-joined → e.g. `B0`.
   Omitted entirely (with no leading dot) when all six bytes are zero.

→ `hvc1.1.6.L93.B0`. The two error-prone parts — the 32-bit reversal and the trailing-zero
omission — are pinned directly by the unit test.

## Components (all in `lib/iso_media/codec.ex`)

- **`parse_entry("hvc1", entry, base)` / `parse_entry("hev1", entry, base)`** — VisualSampleEntry,
  same layout as `avc1`: `width`@offset 32, `height`@offset 34, child boxes begin at offset 86.
  Each guards `byte_size(entry) >= 86`, slices the children, finds the `hvcC` via the existing
  `find_sub_box/2`, and returns
  `%{base | type: :video, codec: hvc1_codec(<fourcc>, hvcC), width: width, height: height}`.

- **`hvc1_codec(fourcc, hvcC_payload)`** — one binary pattern match extracting all fields, builds
  the string above. A catch-all clause raises `ArgumentError` on a short/invalid payload:

  ```elixir
  defp hvc1_codec(fourcc, <<
         _config_version::8, profile_space::2, tier_flag::1, profile_idc::5,
         compatibility_flags::32, c1::8, c2::8, c3::8, c4::8, c5::8, c6::8,
         level_idc::8, _rest::binary
       >>) do
    # profile / compatibility / tier+level / constraints → "<fourcc>.<…>"
  end

  defp hvc1_codec(_fourcc, _bad), do: raise(ArgumentError, "track_info: truncated/invalid hvcC")
  ```

- **`reverse_32_bits(val)`** — reverses the 32 compatibility-flag bits via a 1-bit binary
  pattern match (`<<b1::1, …, b32::1>> = <<val::32>>` → `<<b32::1, …, b1::1>>`). No `Bitwise`,
  compiles to raw bit-swaps.

## Data flow

`read("file.mp4")` → `track_info(boxes, tid)` → find `trak` → `stsd` first entry → dispatch on
fourcc → `hvc1`/`hev1` clause → `find_sub_box(children, "hvcC")` → `hvc1_codec/2` →
`%TrackInfo{type: :video, format: "hvc1"|"hev1", codec: "hvc1.…", width:, height:, …}`. Pure,
read-only; no tree mutation. Manifest generation (`ISOMedia.Manifest.codecs/1`) then joins it
like any other codec — no manifest-layer change needed.

## Testing

- **`hvcC` codec-string units (primary gate, no fixture):** hand-built `hvcC` byte payloads →
  exact expected strings. Cover: Main profile (`hvc1.1.6.L93.B0`); a **bit-reversal** case (a
  non-trivial compatibility value); a **multi-nonzero-constraint** case (e.g. two trailing
  constraint bytes → `…90.80`); the **all-zero-constraints** case (section omitted); a
  **profile-space prefix** case (space 1 → `A…`); high **tier** (`H…`); and an `hev1` fourcc →
  `hev1.*`. Assert uppercase hex.
- **Truncation raises:** an `hvcC` payload < 13 bytes raises `ArgumentError`.
- **Integration (real fixture):** a small committed `test/fixtures/sample_hevc.mp4` —
  generated neutrally, not derived from any personal media:
  `ffmpeg -f lavfi -i testsrc=duration=1:size=320x240:rate=30 -c:v libx265 -profile:v main`
  `-pix_fmt yuv420p -tag:v hvc1 test/fixtures/sample_hevc.mp4`. If `libx265` is unavailable at
  implementation time, fall back to another short, neutral HEVC clip; the unit tests remain the
  correctness gate. Asserts: `track_info` → `type: :video`, `format: "hvc1"`, the fixture's real
  codec string (pinned to the value observed during implementation), and `width: 320`,
  `height: 240`.
- **Unblocking proof:** on the fixture (fragmented first), `hls_master_playlist/2` and
  `dash_manifest/2` now return a string whose codec attribute starts with `hvc1.` — the exact
  calls that previously raised.
- **Round-trip untouched:** `serialize(parse("sample_hevc.mp4")) == File.read!(...)` still holds
  (guards that the targeted `hvcC` parse didn't leak into the core).

## Scope boundary (explicit deferrals)

- **Structured HEVC fields** on `%TrackInfo{}` (profile/tier/level) — codec string only for now.
- **Dolby Vision** (`dvh1`/`dvhe`/`dvav`), **VVC** (`vvc1`/`vvi1`), **AV1** (`av01`) — each its
  own config parse + fixture (AV1 is a separate roadmap line).
- **Multiple sample entries per `stsd`** — unchanged from Phase 12 (first entry only).

## Risks

- **Bit-reversal / trailing-zero omission** are the fiddly bits — neutralized by the dedicated
  unit cases that pin both directly, independent of any fixture.
- **`hvcC` offset assumptions** (VisualSampleEntry `width`@32, children@86; 13-byte config
  header) are fixed by ISO 14496-15; the real-fixture test catches any miscalculation
  immediately (wrong dimensions or a missing `hvcC`).
- **Fixture toolchain** — `libx265` may not be compiled into the local `ffmpeg`; the fallback
  plus the fixture-independent unit gate bound the blast radius.
