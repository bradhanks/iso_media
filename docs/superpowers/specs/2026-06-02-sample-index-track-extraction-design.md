# Design: sample index + single-track extraction

**Date:** 2026-06-02
**Status:** Approved (design phase)
**Builds on:** Phase 1 (lossless box surgery), Phase 2 (chunk-offset rewriting + faststart), Phase 3 (lazy file-backed payloads).

## Goal

Take the first step toward true sample-level editing: decode a track's sample
tables into a flat sample index, and extract a single track into its own valid file
(rebuilding `mdat` + chunk offsets) — memory-safely, preserving Phase 3's
larger-than-RAM guarantee. This is slice 1 of a multi-phase effort; trim
(time/sample range) and concatenation are later specs.

## Background — the sample tables

A track's `stbl` stores tables you cross-reference to locate each sample's bytes:
`stsz` (size per sample, or one uniform size), `stsc` (sample-to-chunk runs),
`stco`/`co64` (chunk file offsets), `stts` (decode-time deltas), `ctts` (optional
composition offsets), `stss` (optional sync-sample list). A **chunk holds samples
of a single track**, contiguous on disk — so a track's media is a handful of
contiguous byte ranges, not thousands of scattered reads.

## Decisions (from brainstorming)

- **Scope:** sample index (read) + `extract_track` (keep one track). No table
  rebuild beyond chunk offsets (whole-track keeps `stts`/`stsc`/`stsz` intact).
- **Rebuilt `mdat`:** a **segment list** (`data` may be `[binary | %FileSlice{}]`),
  streamed disk→disk on `write/2` — memory-safe, and the natural model for later
  trim/concat.
- **`%Sample{}` includes `chunk_index`** so `Enum.chunk_by/2` yields the contiguous
  on-disk runs directly.
- **`stz2` deferred:** raise a clear "unsupported sample-size table" error.
- **1-based** `index`/`chunk_index` (match ISOBMFF numbering / inspection tools).

## Components

### `ISOMedia.Sample` (new — `lib/iso_media/sample.ex`)
```elixir
defstruct [:index, :chunk_index, :dts, :pts, :size, :offset, :sync?]
```
- `index` — 1-based sample number.
- `chunk_index` — 1-based chunk number the sample belongs to.
- `dts` / `pts` — decode / composition time, in the track's `mdhd` timescale
  (`pts = dts + ctts_offset`; `pts == dts` when no `ctts`).
- `size` — sample byte length.
- `offset` — absolute file byte offset of the sample.
- `sync?` — keyframe flag (true for all samples when `stss` is absent).

### `ISOMedia.SampleTable` (new — `lib/iso_media/sample_table.ex`)
`build(trak_box) :: [%Sample{}]` — decodes the track's `stbl` (found via
`Box.find(trak, ~w(mdia minf stbl ...))`) by cross-referencing the tables. Inline
decoders share `ISOMedia.FullBox` for the version/flags prefix:

- `stsz`: `version/flags`, `sample_size`, `sample_count`; if `sample_size == 0`,
  read `sample_count` explicit 32-bit sizes, else every sample has `sample_size`.
  An `stz2` box (instead of `stsz`) → **raise** `ArgumentError`
  ("Unsupported sample-size table: stz2 …").
- `stco`/`co64`: chunk offsets (reuse `ISOMedia.Boxes.ChunkOffset`).
- `stsc`: entries `{first_chunk, samples_per_chunk, sample_description_index}`;
  expand the runs to a samples-per-chunk count for every chunk (`1..chunk_count`).
- `stts`: entries `{sample_count, sample_delta}` → cumulative `dts` per sample.
- `ctts` (optional): entries `{sample_count, sample_offset}` → per-sample `pts`
  offset; absent ⇒ `pts = dts`.
- `stss` (optional): list of sync sample numbers; absent ⇒ all `sync?: true`.

Build algorithm:
1. `sizes` = decode `stsz` (length must equal `sample_count`).
2. `chunk_offsets` = decode `stco`/`co64` (length = `chunk_count`).
3. `spc` = expand `stsc` over `1..chunk_count`.
4. Walk chunks in order; within chunk `c` (offset `O`, `spc[c]` samples), assign
   consecutive sample numbers, `chunk_index: c`, and `offset = O + Σ(prior in-chunk
   sizes)`. (Σ of `spc` must equal `sample_count`.)
5. `dts` from `stts` (cumulative); `pts = dts + ctts_offset`; `sync?` from `stss`.

Missing a required table (`stsz`/`stco|co64`/`stsc`/`stts`) → raise `ArgumentError`.
Exposed as `ISOMedia.samples(boxes, track_id)`.

### Model extension — segment-list payload
A leaf's `data` may now be a **list** `[binary | %FileSlice{}]` ("concatenate these
parts"). Affected modules:

- `ISOMedia.Box` — `@type t` `data: binary() | ISOMedia.FileSlice.t() | [binary() |
  ISOMedia.FileSlice.t()] | nil`. `read_data/1` on a list → concatenate parts
  (reading any `FileSlice`s). `container?`/`leaf?` unaffected (a list is `data != nil`
  ⇒ leaf).
- `ISOMedia.Layout` — `box_size/1` clause for list data → `header_size + Σ part
  lengths` (`byte_size` for binaries, `.length` for `FileSlice`s).
- `ISOMedia.Serializer`:
  - `materialize/1` — a list payload → one concatenated binary (reading
    `FileSlice`s), so `to_iodata` never sees a list.
  - `stream/3` — a list payload → stream each part in order (binary via `write!`,
    `FileSlice` via `FileSlice.stream/3`). Memory-safe.
  - `to_iodata/1` — `encode_payload(%Box{data: data}) when is_list(data)` → **raise**
    a clear `ArgumentError` (use `write/2`/`serialize/1`), mirroring the `FileSlice`
    guard.

### `ISOMedia.extract_track(boxes, track_id)`
Returns a new tree containing only the named track. Steps:

1. Find the `trak` whose `tkhd` `track_id` matches (raise if none). Build its sample
   index.
2. `Enum.chunk_by(samples, & &1.chunk_index)` → contiguous runs. For each run:
   `offset` = first sample's `offset`, `length` = Σ sample sizes. Find the top-level
   `mdat` whose source range `[source_offset, source_offset + source_size)` contains
   `offset`; emit a **segment**:
   - `mdat.data` is `%FileSlice{path: p}` (lazy) → `%FileSlice{path: p, offset:
     offset, length: length}`;
   - `mdat.data` is a binary (eager) → `binary_part(data, offset −
     (mdat.source_offset + header_size(mdat)), length)`.
   (A run offset outside every `mdat` → raise.)
3. New `mdat` payload = the **list of segments**. The kept track's
   `stsd`/`stts`/`stsc`/`stsz`/`ctts`/`stss` are **unchanged**; only `stco`/`co64`
   is rebuilt.
4. **Offsets (chicken-and-egg, resolved up front).** Both unknowns are knowable
   before building `moov`:
   - **`mdat` header size:** total media = `Σ run lengths` (known). If `8 + total`
     fits in 32 bits, header is 8 bytes (`:compact`); else 16 bytes (`:large`,
     size==1 + 64-bit largesize).
   - **`stco` vs `co64`:** decide from a *conservative upper bound* of the output
     size — `byte_size(ftyp) + moov_size_if_co64 + mdat_header + total_media` (i.e.
     assume the larger `co64` table and the chosen `mdat` header). If that bound
     ≤ `0xFFFFFFFF` use `stco`; else `co64`. The output is strictly ≤ the original
     file, so this never under-provisions, and the bound is monotone (using the
     larger table can only push toward `co64`, never flip back).
   With both decided, build `moov` (with the chosen offset-table kind filled with
   dummy offsets) to measure its exact byte size; then
   `new_mdat_payload_start = byte_size(ftyp) + byte_size(moov) + mdat_header_size`;
   then fill chunk `i`'s offset = `new_mdat_payload_start + Σ(prior run lengths)`.
   Re-encode the offset box into the kept track's `stbl`. (Chunk count is preserved,
   so the offset table's size is stable once its kind is fixed.)
5. New tree: original `ftyp`; `moov` keeping its `mvhd` + the one `trak` (other
   `trak`s dropped; other `moov` children e.g. `udta` kept); the new `mdat`
   (`size_mode` per step 4). Output layout is `ftyp, moov, mdat` (moov-first), so all
   offsets are computable before writing. `mvhd`/`tkhd` are left as-is — valid, if
   slightly stale on movie duration / `next_track_ID` (documented; a later phase can
   tidy these).

### Public API (`ISOMedia`)
- `samples(boxes, track_id)` → `[%Sample{}]` (delegates to `SampleTable`).
- `track_ids(boxes)` → `[non_neg_integer]` — each `trak`'s `tkhd` `track_id`, in
  document order (discoverability).
- `extract_track(boxes, track_id)` → new box tree (then `write/2` or `serialize/1`).

## Error handling

All `ArgumentError` with clear messages; functions return plain trees (editing-API
style):
- Unknown `track_id`.
- `stz2` sample-size table.
- Missing required table (`stsz`/`stco|co64`/`stsc`/`stts`).
- A sample/chunk run offset outside every top-level `mdat`.
- Table inconsistency (Σ `spc` ≠ `sample_count`, or `sizes` length ≠ `sample_count`).

## Testing

**Test-support lift:** `MP4Builder` currently emits only `stco`, so it can't drive
the index. Work required:
- **Extend `MP4Builder`** to emit a full valid `stbl` (`stsd` stub, `stts`, `stsc`,
  `stsz`, `stco`, `stss`) for one or more tracks, with caller-specified per-sample
  sizes/durations/sync flags and chunking — the deterministic oracle.
- **Add a 2-track fixture** `test/fixtures/sample_av.mp4` (video+audio via ffmpeg)
  for real multi-track extraction; document regeneration in
  `test/fixtures/README.md`.

Tests:
- **`SampleTable.build`** on a built file: exact `index`/`chunk_index`/`dts`/`pts`/
  `size`/`offset`/`sync?`; `stz2` and missing-table and unknown-id raise.
- **Segment-list payload:** `Layout.box_size`, `materialize`, `stream/3`, and
  `read_data` round-trip for a list of mixed binary + `FileSlice` parts.
- **`samples/2` on real `sample.mp4`:** plausible count; `dts` monotonic
  non-decreasing; every `offset + size ≤ file size`; ≥1 sync sample.
- **Extraction (headline):** `extract_track` the video track out of `sample_av.mp4`
  → re-parse output → exactly one `trak`; its `samples/2` resolve; **each extracted
  sample's bytes == the corresponding original sample's bytes**. Run both eager and
  lazy; lazy keeps the new `mdat` as `FileSlice` segments and `write/2` streams it.
- **Property (`MP4Builder` multi-track):** extract each track; assert the extracted
  track's per-sample bytes equal the originals and the output re-parses to one
  track; assert `lazy-extract-write == eager-extract-serialize`.

## Project layout (new/changed files)

```
lib/iso_media/sample.ex                # NEW: %Sample{}
lib/iso_media/sample_table.ex          # NEW: build/1 (decode stbl → [%Sample{}])
lib/iso_media/extract.ex               # NEW: extract_track impl (or keep in iso_media.ex if small)
lib/iso_media/box.ex                   # + list payload in read_data/1 and @type t
lib/iso_media/layout.ex                # + box_size list clause
lib/iso_media/serializer.ex            # + list handling in materialize/1, stream/3, to_iodata guard
lib/iso_media.ex                       # + samples/2, track_ids/1, extract_track/2
test/support/mp4_builder.ex            # extend: full stbl + multi-track
test/fixtures/sample_av.mp4            # NEW: 2-track fixture
test/iso_media/sample_table_test.exs
test/iso_media/extract_test.exs
test/iso_media/extract_property_test.exs
```

## Out of scope (this phase)

- Trim to a time/sample range, keyframe alignment, multi-track-by-time selection.
- Concatenation.
- Rewriting `mvhd`/`tkhd`/`mdhd` duration or `next_track_ID` (left valid-but-stale).
- `stz2` (compact sample sizes) — raise.
- Fragmented MP4 (`moof`/`trun`) and HEIF (`iloc`).
- Re-chunking / interleaving optimization (extraction preserves the track's existing
  chunking).
