# Design: track codec & media metadata extraction (TrackInfo)

**Date:** 2026-06-05
**Status:** Draft (design phase)
**Builds on:** Phases 1-11 (… fMP4 indexing/defragment, fragmenting, CMAF segment emission).

## Goal

`ISOMedia.track_info(boxes, track_id)` → `%ISOMedia.TrackInfo{}`: decode a track's
codec and media metadata from its `stsd` sample entry and `mdhd`, including the RFC 6381
**codec string** (`"avc1.64001f"` / `"mp4a.40.2"`) that streaming manifests require. This is
**Sub-project B1** of the DASH/CMAF manifest frontier — the foundational, box-parsing piece
that the DASH (B2) and HLS (B3) manifest generators will both consume. The manifests
themselves are out of scope.

The library has so far kept `stsd` **opaque** (concat byte-compares it; trim/fragment copy it
verbatim). B1 is the first code to look *inside* it — but only the small, targeted way needed
for codec metadata; the core parser and Registry are untouched, preserving the byte-for-byte
round-trip invariant.

## Decisions (from brainstorming)

- **Codec scope v1: `avc1` (H.264) + `mp4a` (AAC).** Covers the fixtures and the dominant web
  MP4. Any other sample-entry format raises `ArgumentError`. HEVC/AV1/subtitle codecs are
  deferred (each needs its own config parse + a fixture).
- **`type :: :video | :audio`** — the only values v1 produces. `:subtitle` joins the union when
  subtitle codec support lands.
- **`bitrate` is out of scope.** It is a computed average over the sample-size table (`stsz`),
  not `stsd` metadata; the manifest phase computes it from the already-available `samples/2`.
  B1 stays a pure metadata extractor, not a sample analyzer.
- **Struct, not map.** `%TrackInfo{}` with `nil` for the non-applicable type's fields gives a
  clean `@type`/`@spec` and matches the codebase's typed views (`Sample`, `Handler`, …).
- **Targeted parsing, parser untouched.** `track_info` slices the opaque `stsd`/`avc1`/`mp4a`
  bytes directly. `avc1`/`mp4a` are NOT added to the Registry container set (that would change
  parsing and risk the round-trip invariant).

## The struct

`lib/iso_media/track_info.ex`:

```elixir
defmodule ISOMedia.TrackInfo do
  @type type :: :video | :audio
  @type t :: %__MODULE__{
          track_id: pos_integer(),
          type: type(),
          format: String.t(),          # "avc1" | "mp4a"
          codec: String.t(),           # RFC 6381, e.g. "avc1.64001f" / "mp4a.40.2"
          timescale: pos_integer(),    # mdhd
          duration: non_neg_integer(), # mdhd (media timescale)
          language: String.t(),        # ISO 639-2/T 3-letter, e.g. "eng" / "und"
          width: pos_integer() | nil,  # video
          height: pos_integer() | nil, # video
          sample_rate: pos_integer() | nil, # audio (Hz)
          channels: pos_integer() | nil     # audio
        }
  defstruct [:track_id, :type, :format, :codec, :timescale, :duration, :language,
             :width, :height, :sample_rate, :channels]
end
```

## Components

- **`ISOMedia.TrackInfo`** — the struct above.
- **`ISOMedia.Codec`** (`lib/iso_media/codec.ex`) — the `stsd` sample-entry parser:
  - `info(trak)` → `%TrackInfo{}`: read `track_id` (`tkhd`), `mdhd` via `MediaHeader`
    (`timescale`, `duration`, and `language` from the first 16 bits of `MediaHeader.rest`:
    `<<_pad::1, c1::5, c2::5, c3::5, _::16>>` → `List.to_string([c1+0x60, c2+0x60, c3+0x60])`,
    which yields `"und"` for the common `0x55C4`). Dig `stsd`, take the first sample entry,
    dispatch on its 4-char format.
  - **`avc1`** (VisualSampleEntry): `width`@offset 32 / `height`@offset 34 (16-bit each, from
    the entry start); the child boxes begin at offset 86 — walk them for `avcC`; its payload
    bytes `[1]`,`[2]`,`[3]` are `profile_idc`, `profile_compatibility`, `level_idc` →
    `codec = "avc1." <> Base.encode16(<<p, c, l>>, case: :lower)` (e.g. `"avc1.64001f"`).
    `type: :video`, `format: "avc1"`.
  - **`mp4a`** (AudioSampleEntry): `channels`@offset 24 (16-bit), `sample_rate`@offset 32
    (32-bit 16.16 fixed — integer part is the high 16 bits); child boxes begin at offset 36 —
    walk for `esds`. Parse the `esds` MPEG-4 descriptors (after the FullBox 4-byte prefix):
    ES_Descriptor tag `0x03` → DecoderConfigDescriptor tag `0x04` (first payload byte =
    `objectTypeIndication`) → DecoderSpecificInfo tag `0x05` (AudioSpecificConfig; top 5 bits
    of its first byte = `audioObjectType`). Each descriptor uses the expandable size encoding
    (size bytes with the high bit as a continuation flag). `codec = "mp4a." <> hex(oti) <>
    "." <> Integer.to_string(aot)` (e.g. `"mp4a.40.2"`). If the `esds` cannot be walked, fall
    back to `"mp4a.40.2"` (documented degradation — AAC-LC dominates). `type: :audio`,
    `format: "mp4a"`.
  - any other format → `raise ArgumentError, "track_info: unsupported codec <fmt>"`.
- **`ISOMedia.track_info/2`** — finds the `trak` (reuse `ISOMedia.Extract.find_trak/2`) and
  delegates to `Codec.info/1`; raises if the track is absent.
- A small `child-box scan` helper (walk `<<size::32, type::4-bytes, payload>>` records within a
  byte slice to find a sub-box by type) is shared by the `avcC`/`esds` lookups.

## Data flow

`read("movie.mp4")` → `track_info(boxes, track_id)` → find `trak` → `MediaHeader` (timescale,
duration, language) + `stsd` first sample entry → dispatch (`avc1`/`mp4a`) → parse the codec
config sub-box → `%TrackInfo{}`. Pure, read-only; no tree mutation.

## Testing

- **Real fixture (the anchor):** `track_info(read("sample_av.mp4"), <video_tid>)` →
  `type: :video`, `format: "avc1"`, `width: 128`, `height: 96` (the `testsrc=size=128x96`
  values), a `codec` matching the fixture's actual `avc1.PPCCLL` (pinned to the value observed
  during implementation, e.g. via `ffprobe`), and a `timescale`/`duration`/`language`.
  `track_info(…, <audio_tid>)` → `type: :audio`, `format: "mp4a"`, `codec` `"mp4a.40.2"`,
  `sample_rate` and `channels` matching the AAC fixture, language.
- **Codec-string units:** hand-built `avcC` bytes (e.g. profile `0x64`, compat `0x00`, level
  `0x1f`) → `"avc1.64001f"`; hand-built `esds` descriptors (AAC-LC) → `"mp4a.40.2"`.
- **Language:** a synthetic `mdhd` with `0x55C4` → `"und"`, and one with `"eng"` packed →
  `"eng"`.
- **Raises:** a `stsd` whose first entry is an unsupported format (e.g. `"hvc1"`) raises
  `ArgumentError`; a missing `track_id` raises.
- **Round-trip untouched:** assert `serialize(parse(sample_av.mp4)) == sample_av.mp4` still
  holds (B1 adds no parser/registry change) — a guard that the targeted parsing didn't leak
  into the core.

## Scope boundary (explicit deferrals)

- DASH `.mpd` (B2) and HLS `.m3u8` (B3) generation — separate follow-on phases that consume
  `%TrackInfo{}`.
- HEVC (`hvc1`/`hev1`), AV1 (`av01`), and other codecs; subtitle/text tracks — each needs its
  own config parse and a fixture.
- `bitrate`/`bandwidth` — computed by the manifest phase from `samples/2`.
- Multiple sample entries per `stsd` (codec changes mid-track) — v1 reads the **first** entry
  and ignores any others (a single entry is the norm; multi-entry handling is deferred).

## Risks

- **`esds` descriptor parsing** (expandable sizes, nested tags) is the fiddliest part; the
  `"mp4a.40.2"` fallback bounds the blast radius, and the codec-string unit test pins the
  happy path.
- **Sample-entry offset assumptions** (`width`@32, child boxes@86 for `avc1`; `esds`@36 for
  `mp4a`) are fixed by the ISO spec; the real-fixture test catches any miscalculation
  immediately (wrong width/height or a missing `avcC`/`esds`).
- **Targeted parsing leaking into the core** — guarded by the round-trip assertion in tests.
