# Design: time-based trim (all tracks, lossless, interleave-preserving)

**Date:** 2026-06-02
**Status:** Approved (design phase)
**Builds on:** Phase 1 (lossless box surgery), Phase 2 (chunk-offset rewriting), Phase 3 (lazy payloads), Phase 4 (sample index + extraction / segment-list payloads).

## Goal

Losslessly trim every track of an ISOBMFF file to a time range `[start_sec, end_sec)`
without re-encoding: keep the samples in range, snap the video start back to the
nearest keyframe so the result decodes, rebuild each track's sample tables and the
`mdat`, update the duration headers, and re-base the timeline to zero — all
memory-safely (the new `mdat` is a segment list, so lazy trees stream disk→disk).
This is the next sample-editing slice after extraction; `elst`/frame-accurate start
and concatenation are later specs.

## Decisions (from brainstorming)

- **Time-based, all tracks** — `trim(boxes, start_sec, end_sec)` selects each track's
  samples in range (seconds converted per track via `mdhd` timescale), keeping A/V in
  sync.
- **Snap-to-keyframe start** — the kept set begins at the last sync sample with
  `dts ≤ start_ts` (full GOP for the first frame); audio (all-sync) just lands at/just
  before the start. `elst` (frame-accurate presentation start) is deferred.
- **`dts`-based exclusive end** — keep samples with `dts < end_ts`.
- **Timeline re-bases to 0** — the rebuilt `stts` holds only the kept durations,
  cumulative from zero; no offset math needed.
- **Interleave preserved** — kept chunk-runs from all tracks are written to the new
  `mdat` sorted by their original file offset (NOT collapsed to one block per track,
  which would de-interleave A/V and ruin progressive/streaming playback).
- **`%Sample{}` gains `duration`** — required to rebuild `stts` (the last sample's
  duration is unrecoverable from `dts` differences; `stts` holds it natively).

## Components

- **`ISOMedia.Sample`** — add a `duration` field (track-timescale units).
- **`ISOMedia.SampleTable`** — populate `duration` during `build/1`; add table
  **encoders** (`stts`/`ctts`/`stsz`/`stss`/`stsc`/`stco` boxes) rebuilt from a kept
  sample list. (Today it only decodes.) Encoders share `FullBox`.
- **`ISOMedia.Trim`** (new — `lib/iso_media/trim.ex`) — `trim/3`. Orchestrates
  selection, table rebuild, `mdat` segment assembly, offset/duration computation.
- Reuses: `ChunkOffset` (stco/co64), `MovieHeader`/`TrackHeader`/`MediaHeader` (duration
  edits, lossless via their raw `rest`), `Layout` (sizing/offsets), segment-list
  payloads, and `Extract`'s `segment_for`-style mdat lookup (factor the shared helper
  into a small module both can use, e.g. `ISOMedia.MdatSource`, rather than duplicate).
- **`ISOMedia.trim/3`** public delegation.

## Selection (per track)

1. `samples = SampleTable.build(trak)`; `ts = mdhd timescale`;
   `start_ts = round(start_sec * ts)`, `end_ts = round(end_sec * ts)`.
2. **start index** = the last sample with `sync? and dts ≤ start_ts` (snap to
   keyframe). If `start_ts ≤ first sample dts`, start at sample 1.
3. **end** = keep through the last sample with `dts < end_ts`.
4. Kept = the contiguous sample-number range `[start_index, end_index]`.
5. Empty (start past the track, or `end_ts ≤ start_ts`, or no sample qualifies) →
   raise `ArgumentError`.

## Per-track table rebuild (from kept samples K)

- **`stts`** = run-length-encode `[s.duration for s <- K]`.
- **`ctts`** = RLE of `[s.pts - s.dts for s <- K]`; emit the box only if any nonzero
  (version 0; offsets are ≥ 0 after re-base in practice, but keep the original box's
  version if present).
- **`stsz`** = explicit sizes `[s.size for s <- K]` (`sample_size = 0`).
- **`stss`** = the 1-based positions (within K) of kept samples that are `sync?`,
  renumbered; **omit** the box entirely when every kept sample is sync (audio).
- **`stsc`/`stco`** (interleave-preserving):
  - Group K into runs with `Enum.chunk_by(& &1.chunk_index)` — each run is the kept
    portion of one original chunk (boundary runs partial, interior whole).
  - Each run becomes a chunk: byte offset = first sample's `offset`, length = Σ sizes,
    `samples_per_chunk` = run length.
  - `stsc` = RLE over the track's runs of `samples_per_chunk` (`first_chunk` 1-based in
    the track's new chunk numbering).
  - `stco`/`co64` = the runs' **new** absolute offsets (computed in §mdat).
- `stsd` and the rest of `stbl`/`minf`/`mdia` unchanged except the rebuilt tables.

## mdat assembly, offsets, durations

1. Collect every kept chunk-run across all tracks, each tagged `{track_id,
   orig_offset, length, run_index_within_track}`. **Sort by `orig_offset`** → the
   global write order (preserves interleaving).
2. New `mdat` payload = the runs in that order, each a **segment**: `%FileSlice{path,
   orig_offset, length}` when the source `mdat` is lazy, else `binary_part(mdat_data,
   orig_offset - mdat_payload_start, length)`. The containing source `mdat` is found by
   offset range (shared `MdatSource` helper; raise if a run offset is outside every
   `mdat`).
3. **Offsets:** decide each track's `co64`-vs-`stco` and the new `mdat` header size up
   front via conservative upper bounds (as in `extract_track`: assume `co64` tables +
   16-byte header; output ≤ original size). Build `moov` with dummy offsets to measure
   its size via `Layout.box_size`; `mdat_payload_start = box_size(ftyp) + box_size(moov)
   + mdat_header`. Walk the sorted runs assigning new absolute offsets; map each run
   back to its track to fill that track's `stco`/`co64` (in track-chunk order, which the
   global sort preserves).
4. **Durations** (reuse Phase 1 typed views, which keep a raw `rest` so edits round-trip
   losslessly): `mdhd.duration` = Σ kept durations (track timescale); `tkhd.duration` =
   that value scaled to the movie timescale (`mvhd.timescale`); `mvhd.duration` = max of
   the tracks' `tkhd.duration`. `next_track_ID` and all timescales unchanged.
5. Output tree: original `ftyp`; `moov` keeping `mvhd` (duration updated) + every track
   (tables + durations rebuilt) + other `moov` children (e.g. `udta`); new `mdat`.

## Error handling

`ArgumentError` with clear messages; `trim/3` returns the plain tree:
- `end_sec ≤ start_sec`, or the range selects no samples for some track.
- A track that can't be indexed (propagates `SampleTable` raises: `stz2`, missing
  table, etc.).
- A kept chunk-run offset outside every top-level `mdat`.
- (Tracks with no samples in range make trim ill-defined → raise, rather than emit a
  zero-sample track.)

## Testing

- **Extend `MP4Builder`** so a track spec can carry per-sample **durations** and
  **sync flags** (currently duration is fixed at 1 and all samples are sync), so trims
  and keyframe-snapping are testable deterministically.
- **Unit (`MP4Builder` multi-track):** trim a known time range and assert —
  - kept samples' bytes are byte-identical to the originals;
  - `stts`/`stsz`/`stsc`/`stss` rebuilt correctly for the kept set (verified via
    `SampleTable.build` on the output matching the expected kept samples);
  - **interleave order preserved** — the output `mdat`'s chunk runs are in original-
    offset order (decode both tracks' `stco` from the output and confirm chunk offsets
    interleave, not block-per-track);
  - timeline re-based to 0 (first kept sample `dts == 0`);
  - durations updated (`mdhd`/`tkhd`/`mvhd`).
- **Keyframe snap:** a track with sparse `stss`; request a `start_sec` between
  keyframes → output's first sample is the preceding keyframe (sync), earlier than
  `start_sec`.
- **Real `sample_av.mp4` integration:** trim a sub-range; re-parse; both tracks present
  with samples; each kept sample's bytes equal the original's; A/V chunk interleaving
  preserved; durations sane. Run eager and lazy; lazy `trim |> write` == eager `trim |>
  serialize`.
- **Property (`MP4Builder` multi-track, random ranges):** every kept sample byte-
  identical; output re-parses to the same track set; interleave preserved; idempotent-
  ish (trimming `[0, full_duration)` ≈ the original sample set).

## Project layout (new/changed files)

```
lib/iso_media/sample.ex          # + duration field
lib/iso_media/sample_table.ex    # populate duration; add table encoders
lib/iso_media/mdat_source.ex     # NEW: shared "segment for offset range" (used by Extract + Trim)
lib/iso_media/extract.ex         # refactor to use MdatSource (no behavior change)
lib/iso_media/trim.ex            # NEW: trim/3
lib/iso_media.ex                 # + trim/3 delegation
test/support/mp4_builder.ex      # per-sample durations + sync flags
test/iso_media/trim_test.exs
test/iso_media/trim_av_test.exs
test/iso_media/trim_property_test.exs
```

## Out of scope (this phase)

- `elst` / frame-accurate presentation start (snap-to-keyframe only; output begins at
  the keyframe).
- Concatenation.
- Re-chunking/interleaving *optimization* (we preserve the source's interleave order;
  we don't re-derive an optimal one).
- Adjusting per-sample composition (`ctts`) to compensate for the snapped leading
  frames (that's part of the `elst` phase).
- `stz2`, fragmented MP4, HEIF.
