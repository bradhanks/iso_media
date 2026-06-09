# Roadmap

Deferred and future work for `iso_media`. This is a **menu, not a commitment** — items
were deliberately scoped out of earlier phases to keep each one shippable. Each entry notes
its source (a spec's "Scope boundary" section or a capability-gap `raise` in the code).

The guiding invariant for everything below is unchanged: **byte-for-byte round-trip**
(`serialize(parse(file)) == file`) and **zero runtime dependencies**.

## Shipped

- **0.1.0** — box-tree surgery, faststart, lazy file-backed payloads, sample index + track
  extraction, time-based / frame-accurate trim, lossless concat, recursive virtual I/O,
  fragment / defragment, CMAF segment emission.
- **0.2.0** — `track_info/2` codec metadata, HLS playlist generation, DASH MPD generation.
- **Unreleased** — **virtual seekable media**: `seek_index/1` + `read_range/3` (pread-style) +
  `stream_range/4` (lazy, leak-safe) return any byte range of a tree's serialization without
  materializing it; a streaming-origin primitive. Byte-exact against `serialize/1`.

## Next up (leading candidate)

1. **ABR / multi-bitrate manifests** — multiple `Representation`s (DASH) / `#EXT-X-STREAM-INF`
   variants (HLS). The actual point of adaptive streaming; larger, since it needs a
   multi-encode ingest path the library doesn't yet produce.

(HEVC support — previously the top candidate — **shipped** in Unreleased; see Codec coverage.)

---

## Codec coverage

`track_info/2` currently supports `avc1` (H.264), `hvc1`/`hev1` (HEVC), and `mp4a` (AAC); every
other sample-entry format raises. Manifests can only describe what `track_info/2` can decode,
so this gates manifest reach.

- ~~**HEVC** (`hvc1` / `hev1`)~~ — **shipped** (Unreleased): `hvcC` config parse →
  `hvc1.*`/`hev1.*` RFC 6381 string; `track_info/2` + HLS/DASH work on HEVC content.
- **AV1** (`av01`) — `av1C` config parse → `av01.*`. Needs a fixture.
- **Subtitle / text tracks** (`wvtt`, `stpp`, …) — adds `:subtitle` to the `TrackInfo.type`
  union; unblocks subtitle rendition entries in manifests.
- **Multiple sample entries per `stsd`** (codec change mid-track) — today only the *first*
  entry is read. Source: track-info spec deferral.

## Streaming manifests — advanced

Current HLS + DASH emit a **single muxed VOD rendition**. The deferrals below are the real
point of adaptive streaming and are the natural follow-on once multi-encode inputs exist.

- **ABR / multi-bitrate** — multiple `Representation`s (DASH) / `#EXT-X-STREAM-INF` variants
  (HLS). Requires multiple encodes the library does not itself produce, so this likely pairs
  with an external-encode ingest path. Source: HLS + DASH spec deferrals.
- **Demuxed per-track** AdaptationSets / media playlists + audio groups (`#EXT-X-MEDIA`).
- **Live / dynamic** — sliding-window HLS (`#EXT-X-MEDIA-SEQUENCE`, no `ENDLIST`),
  `type="dynamic"` MPD (`availabilityStartTime`, `timeShiftBufferDepth`).
- **`SegmentBase` byte-range** single-file addressing (vs. the current separate-segment layout).
- **Encryption** — CENC `ContentProtection` (DASH) / `#EXT-X-KEY` (HLS); pairs with fMP4
  encrypted-fragment support below.
- **I-frame playlists** (`#EXT-X-I-FRAME-STREAM-INF`), **trick-mode**, **`BaseURL` / CDN**
  absolute-URL rewriting.

## fMP4 indexing gaps

`FragmentIndex` raises on these today:

- **Non-`default-base-is-moof` addressing** (`fragment_index.ex:102`) — the only fragment
  addressing mode currently supported.
- **Encrypted fragments** `senc` / `saiz` / `saio` (`fragment_index.ex:182`) — prerequisite
  for CENC manifest support above.

## Sample-table / editing gaps

- **`stz2`** compact sample sizes (`sample_table.ex:7` raises) — a second `stsz` encoding.
- **Sample-level offset editing** (`offsets.ex`) — chunk-offset *relocation* of a synthesized
  (segment-list) `mdat` now works in memory (`fix_chunk_offsets`/`faststart` no longer raise on
  synthesized trees; see `MdatSource.synthesized_mdat/3`). Still deferred: recomputing offsets
  from `stsc`/`stsz` for genuine payload *reordering/resizing* (a size change still raises).

## Core architecture (deferred from the Phase 8 brainstorm)

Cut to keep "recursive virtual I/O" shippable; revisit if scale demands it.

- **Streaming seam** — a uniform streaming interface so transforms compose without ever
  materializing a full tree.
- **Packed sample index** — a compact columnar `[%Sample{}]` representation for very large
  tracks.
- **Concurrency** — parallelize independent per-track / per-fragment work.

## Process / meta

- **Library-tuned review rubric** — the `elixir-otp-rubric` used by the spec/plan reviewers is
  Phoenix/OTP-shaped; only standards 1 (functional core/shell), 7 (DRY), 8 (build-vs-borrow),
  and 11 (data integrity) genuinely apply to this pure binary library. A replacement set of
  lenses (byte-exact round-trip, parser/format isolation, offset determinism, lazy
  memory-safety, property-based coverage) would fit far better.
