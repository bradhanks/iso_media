# Design: lossless concatenation

**Date:** 2026-06-02
**Status:** Approved (design phase)
**Builds on:** Phases 1-6 (box surgery, faststart, lazy payloads, sample index/extraction, trim, frame-accurate trim).

## Goal

Join N compatible clips end-to-end into one file without re-encoding:
`ISOMedia.concat([boxes1, boxes2, …])`. For each track, append every clip's samples
after the previous clip's, concatenating the sample tables and building one `mdat`
that references every input's source file. Memory-safe (the combined `mdat` is a
segment list). This is the last core sample-editing primitive.

## Decisions (from brainstorming)

- **N inputs, in order** — `concat/1` takes a list of parsed trees (≥1; empty raises).
- **Strict compatibility, keyed on `stsd` + `mdhd` timescale** — all inputs must have
  the same track count; for the i-th track of every input, the `mdhd` timescale must
  match and the `stsd` must be **byte-identical**. Identical `stsd` implies same
  codec/resolution/handler, and protects against track misordering (a video track's
  `stsd` won't match an audio track's). Mismatch → raise. (No separate `hdlr` check;
  `stsd` subsumes it.)
- **By-order track matching** — the i-th track of each input merges into the i-th of
  input 1.
- **Source edit lists are ignored** — concat joins raw media timelines. Documented
  caveat: concatenating clips that were previously *trimmed* will make the hidden
  keyframe lead-in frames visible at the splice points (the per-clip `elst` is not
  translated into a global timeline). Merging edit lists is out of scope.
- **Inputs must be readable files** — a `trim`/`extract`/`concat` *output* has a
  synthesized segment-list `mdat` the sample reader can't resolve; to chain, write the
  intermediate to disk and re-read it. (A recursive `MdatSource` resolver is out of
  scope.)
- **Output movie timescale = input 1's `mvhd` timescale.**

## Compatibility checks (raise `ArgumentError`)

- Empty input list.
- Inputs differ in track count.
- For some track index i: `mdhd` timescales differ, or `stsd` boxes are not
  byte-identical, across inputs.
- Any input whose i-th track can't be sample-indexed (propagates `SampleTable` raises).
- Any input track whose `mdat` payload is already a segment list (a non-file input) —
  `MdatSource` raises ("cannot read from an mdat whose payload is already a segment
  list").

## Per-track build (track index i)

Collect the i-th track's samples from every input via `SampleTable.build`. Concatenate
(input order):
- **`stts`** = `SampleTable.build_stts(durations1 ++ durations2 ++ …)`.
- **`ctts`** = `build_ctts((pts−dts) appended)`; nil if all zero.
- **`stsz`** = `build_stsz(sizes appended)`.
- **`stss`** = sync positions: for each input, the 1-based positions (within that
  input's track) of its sync samples, shifted by the running total sample count of
  prior inputs; concatenated. An input with no `stss` contributes *all* its sample
  positions (all-sync). Omit the box entirely if every input's track is all-sync.
- **`stsc`/`stco`** = the joined chunk list is input1's chunk-runs ++ input2's runs ++
  …, where each input's runs come from `Enum.chunk_by(samples_i, & &1.chunk_index)`;
  `stsc` = RLE of those runs' sample counts (1-based chunk numbering across the joined
  list); `stco` = the runs' new absolute offsets (computed in §mdat).
- `stsd`, plus the rest of `mdia`/`minf` and `tkhd`, taken from **input 1's** i-th
  track (durations updated below). The track's `stbl` is rebuilt with the concatenated
  tables (order: `stsd, stts, [ctts], stsc, stsz, [stss], stco`). Any source `edts` is
  dropped.

## mdat assembly, offsets, durations

1. For each input (in order), gather **all** tracks' chunk-runs tagged `{input_index,
   track_index, source_mdats, orig_offset, length, samples}` and sort them by
   `orig_offset` (preserving that input's interleave). The global write order is
   input-order, then within-input offset-order.
2. New `mdat` payload = those runs as segments, each resolved from **its own input's**
   `mdat`s via `MdatSource.segment(input_mdats, orig_offset, length)` (a `FileSlice`
   over that input's file when lazy, a `binary` slice when eager).
3. **Offsets:** decide `co64`-vs-`stco` and the `mdat` header size up front from a
   conservative bound (output ≈ Σ inputs; assume `co64` tables + 16-byte header).
   Build `moov` with dummy offsets to measure its size via `Layout.box_size`;
   `mdat_payload_start = box_size(ftyp) + box_size(moov) + mdat_header`; assign new
   offsets to the runs in global order; fill each track's `stco` from the new offsets
   of *its* runs (input-then-chunk order).
4. **Durations:** per joined track, `mdhd.duration` = Σ over inputs of that track's
   media duration (Σ sample durations); `tkhd.duration` = scaled to the output movie
   timescale; `mvhd.duration` = max track `tkhd.duration`.
5. Output tree: input 1's `ftyp`; `moov` = input 1's `mvhd` (duration updated) + the
   joined tracks (input 1's `trak` boxes with rebuilt tables/durations, source `edts`
   dropped) + input 1's other `moov` children (e.g. `udta`); the combined `mdat`.

## Components

- **New `ISOMedia.Concat`** (`lib/iso_media/concat.ex`) — `concat/1`. Orchestrates
  compatibility checks, per-track table concatenation, multi-source `mdat` assembly,
  offset/duration computation.
- Reuses: `SampleTable` (decode + `build_stts`/`build_ctts`/`build_stsz`/`build_stss`/
  `build_stsc`), `MdatSource`, `Boxes.ChunkOffset`, `Boxes.MovieHeader`/`TrackHeader`/
  `MediaHeader`, `Layout`, segment-list payloads, and the `update_descendant`/`dig`
  helpers (factor the per-box descendant-update helper into a shared module, e.g.
  `ISOMedia.BoxPath`, if duplicating across `Trim`/`Extract`/`Concat` becomes noise).
- **`ISOMedia.concat/1`** public delegation.

## Testing

- **`MP4Builder` two compatible clips** (identical `stsd` stub + timescale): concat →
  re-parse → each track's samples = clip1's ++ clip2's, **byte-identical** to the
  respective source bytes; sample count = sum; `dts` continuous (clip2's first dts =
  clip1's total duration); `mdhd`/`tkhd`/`mvhd` durations summed.
- **Compatibility raises:** mismatched `stsd`, mismatched timescale, mismatched track
  count, and empty list each raise `ArgumentError`.
- **Real `sample_av.mp4` concatenated with itself** (read twice): output has both
  tracks, double the samples, every sample byte-identical to the source, continuous
  timeline; run eager and lazy; `lazy concat |> write == eager concat |> serialize`.
- **Property (`MP4Builder`, N compatible clips):** total samples = Σ inputs; every
  output sample's bytes equal the corresponding input clip's sample bytes (in order);
  output re-parses to the same track set; lazy == eager.
- **Chaining limitation:** a concat of a `trim` *output* (segment-list `mdat`) raises
  the clear `MdatSource` error (documents the write-then-reread workaround).

## Project layout (new/changed files)

```
lib/iso_media/concat.ex          # NEW: concat/1
lib/iso_media.ex                 # + concat/1 delegation
test/support/mp4_builder.ex      # (already supports the multi-track/full-stbl builds needed)
test/iso_media/concat_test.exs
test/iso_media/concat_av_test.exs
test/iso_media/concat_property_test.exs
README.md / CLAUDE.md            # document concat + its limits
```

## Out of scope (this phase)

- Reconciling mismatched `stsd` (re-encoding, or multi-`stsd` tracks with per-sample
  description indices).
- Translating/merging source edit lists into a global timeline (lead-in frames from
  trimmed inputs become visible at splices — documented).
- Chaining without a disk round-trip (recursive segment-list `mdat` resolution).
- Differing track *counts*/handler-by-handler matching with skips.
- Fragmented MP4, HEIF, `stz2`.
