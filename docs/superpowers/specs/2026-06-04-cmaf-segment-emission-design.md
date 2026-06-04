# Design: CMAF segment emission (fragmented tree → init + media segments)

**Date:** 2026-06-04
**Status:** Draft (design phase)
**Builds on:** Phases 1-10 (box surgery … recursive virtual I/O, fMP4 indexing/defragment, fragmenting).

## Goal

Split a fragmented MP4 tree (the output of `ISOMedia.fragment/2`, or an equivalent
`[ftyp, moov, (moof, mdat)+]` file) into the **DASH/CMAF on-disk layout**: one media-less
**init segment** plus **N standalone media segment files**, each `[styp, moof, mdat]`.
Lossless, memory-safe (each segment's `mdat` stays a source-referencing segment list, so
segments stream disk→disk). This is **Sub-project A** of the DASH/CMAF frontier; manifest
generation (MPD / HLS playlist) is Sub-project B, a separate later phase, and is out of
scope here.

Two public entry points:
- `ISOMedia.split_segments(boxes)` → `%{init: tree, segments: [tree]}` (pure; returns box
  trees).
- `ISOMedia.write_segments(dir, boxes, opts \\ [])` → writes the init + segment files to a
  directory via the existing memory-safe `write/2`; returns the written paths.

## Decisions (from brainstorming)

- **Pure split + thin file-writer.** `split/1` is the real primitive (composable,
  byte-testable); `write_segments/3` is a small convenience that loops `write/2`. The
  reversibility proof targets `split/1`.
- **Structure-preserving (muxed-in → muxed-out).** `split/1` keeps whatever tracks the
  fragmented tree has; a muxed input yields muxed segments. Single-track (per-adaptation-set)
  segments are produced by **composition** — `extract_track |> fragment |> split_segments` —
  not by `split` itself. Demuxing is already solved by `extract_track/2`.
- **1 segment per `moof`+`mdat` pair** (segment == fragment, the CMAF norm).
- **Strict input contract.** Input must be `[ftyp, moov, (moof, mdat)+]` (a `fragment/2`-
  shaped tree). Anything else — progressive (no `moof`), a `moof` without a following
  `mdat`, a missing `ftyp`/`moov` — raises `ArgumentError`. Validating the precondition keeps
  the split logic trivial; robust splitting of arbitrary real-world fMP4 (pre-existing
  `styp`/`sidx`, multi-`moof` segments) is deferred.
- **`styp` built from `ftyp`.** A Segment Type box is structurally identical to `ftyp`
  (major_brand · minor_version · compatible_brands). We construct each segment's `styp` by
  copying the input `ftyp`'s payload under the `styp` type. Proper CMAF brand sets
  (`msdh`/`msix`/`cmfs`) are a deferred refinement; copied brands yield a valid, parseable
  `styp`.
- **No offset surgery.** `fragment/2` emits `default-base-is-moof`, so every `moof`'s sample
  addressing is moof-relative and already self-contained — a `moof`+`mdat` pair is valid
  verbatim inside a segment with no `data_offset` recomputation.

## Components

- **`ISOMedia.Segment`** (`lib/iso_media/segment.ex`):
  - `split/1` — validate the input shape; take `init = [ftyp, moov]` (boxes before the first
    `moof`); pair each `moof` with its following `mdat`; wrap each pair as
    `[styp, moof, mdat]` (styp from `ftyp`). Return `%{init: init, segments: segments}`.
  - `write_segments/3` — `File.mkdir_p(dir)` first (create the directory if absent), then
    `write/2` the init to `dir/init.mp4` and each segment to `dir/seg-<i>.m4s` (1-based;
    `opts[:init_name]` / `opts[:segment_pattern]` override the defaults). Returns
    `{:ok, [paths]}` in written order, or propagates the first `write/2` error as
    `{:error, reason}`. Overwrites existing same-named files (matching `write/2` semantics).
    Memory-safe: each segment's `FileSlice`-backed `mdat` streams disk→disk.
  - `styp/1` (private) — `%Box{type: "styp", data: ftyp.data, size_mode: ftyp.size_mode}`.
- **Exposed as** `ISOMedia.split_segments/1` and `ISOMedia.write_segments/3`.

The `styp` box already parses as a leaf (Registry doesn't list it as a container), so no
parser/registry change is needed — round-trip of a `styp`-containing tree already works.

## Data flow

`read("movie.mp4") |> fragment(target_duration: 4.0)` →
`[ftyp, moov, moof_1, mdat_1, …, moof_n, mdat_n]` → `split_segments` →
`%{init: [ftyp, moov], segments: [[styp, moof_1, mdat_1], …, [styp, moof_n, mdat_n]]}` →
`write_segments("out/", …)` → `out/init.mp4`, `out/seg-1.m4s`, …, `out/seg-n.m4s`
(each `.m4s` streamed from the source bytes). For a track-separated layout, the caller maps
`extract_track |> fragment |> split_segments` over the tracks.

## Testing

- **Reversibility (the correctness anchor):** for `frag = fragment(read("sample_keyint.mp4"))`,
  `split_segments(frag)` then reassemble
  `init ++ Enum.flat_map(segments, fn [_styp, moof, mdat] -> [moof, mdat] end)` and assert it
  **serializes byte-identically to `serialize(frag)`** (the `styp`s are the only added bytes).
- **Self-contained / playable segment:** `init ++ first_segment` is a valid fragmented file;
  `samples/2` over it resolves that segment's samples to the **same bytes** as the
  corresponding samples in `frag` (proves each segment carries correct, independently
  resolvable media).
- **Structure:** `init == [ftyp, moov]` (no `moof`/`mdat`); `length(segments)` == the `moof`
  count; every segment is exactly `[styp, moof, mdat]`; each segment re-parses
  (`parse(serialize(segment))` round-trips) and its `styp` decodes with the `ftyp`'s brands.
- **File writer:** `write_segments(tmp, frag)` writes `init.mp4` + `seg-1.m4s…`; reading them
  back and reassembling equals `serialize(frag)`; the returned paths exist.
- **lazy == eager:** `split_segments` of a lazily-read fragmented file streams to
  byte-identical segment files as the eager path (and never materializes the `mdat`).
- **Raises:** progressive input (no `moof`), a tree missing `ftyp` or `moov`, and a `moof`
  with no following `mdat` each raise a clear `ArgumentError`.

## Scope boundary (explicit deferrals)

- Manifest generation (DASH MPD, HLS `.m3u8`) — **Sub-project B**, separate phase.
- `sidx` (Segment Index) emission for byte-range addressing — deferred.
- Per-track / demuxed split as a built-in — done by composition (`extract_track |> fragment
  |> split_segments`).
- Robust splitting of arbitrary real-world fMP4 (pre-existing `styp`/`sidx`/`mfra`,
  multi-`moof` segments, byte-range single-file segments) — this phase targets
  `fragment/2`-shaped input and raises otherwise.
- Proper CMAF `styp` brand sets (`msdh`/`msix`/`cmfs`) — copies `ftyp` brands for now.
- A single-call per-track convenience wrapper — trivial to add later if wanted.

## Risks

- **Input-shape assumptions** — neutralized by the strict precondition + raise; the
  reversibility test guarantees the split itself loses nothing.
- **`styp` brand correctness** — copied `ftyp` brands are structurally valid and parse; some
  strict CMAF validators may want `msdh`/`msix`. Documented as a refinement, not a blocker.
- **Filename collisions / dir handling in `write_segments`** — `File.mkdir_p` creates the
  directory if absent; existing same-named files are overwritten (matching `write/2`). The
  caller owns the directory's contents.
