# Design: recursive virtual I/O (in-memory pipeline chaining)

**Date:** 2026-06-03
**Status:** Draft (design phase)
**Builds on:** Phases 1-7 (box surgery, faststart, lazy payloads, sample index/extraction, trim, frame-accurate trim, concat).

## Goal

Let the output of one sample-editing operation be the input to the next **entirely in
memory**, with no disk round-trip between stages. Today `trim`, `extract`, and `concat`
each produce a tree whose `mdat` payload is a **segment list** (`[binary | FileSlice]`),
and `MdatSource.segment/3` *raises* when asked to read from such an mdat — so chaining
(`trim |> concat |> trim`) requires writing each intermediate to disk and re-reading it
(documented as out of scope in the concat and trim specs).

Phase 8 removes that wall by making a segment-list element able to be **itself a segment
list**, and teaching `MdatSource` to resolve a byte range recursively through that tree.
This closes the documented gap and unlocks lossless, arbitrary-depth in-memory pipelines
for progressive MP4/MOV/M4A — the foundation streaming assembly (and fMP4, Phase 9) will
build on.

The byte-for-byte invariant is **extended**, not just preserved:

> `serialize(chained-in-memory-ops)` is byte-identical to `serialize(same-ops with a
> disk write+re-read between each stage)`.

## Decisions (from brainstorming)

- **Recursive segment lists, no new struct.** A leaf's `data` becomes a recursive type:
  `binary | FileSlice | [segment]`, where `segment :: binary | FileSlice | [segment]`.
  Nesting is purely functional and immutable. No new data structure is introduced — the
  existing flat segment list simply gains the ability to hold a list as an element.
- **`Layout` is the single source of truth for offsets.** The resolver never re-predicts
  layout independently. Offsets are **captured once** during the same `Layout`-driven
  walk that serialization uses (see `MdatSource.collect/1` below), so there is no second
  computation that could drift.
- **Capture, don't recompute.** `collect/1` records each top-level `mdat`'s absolute
  `payload_start`/`payload_size` from a layout walk, rather than reading the parser's
  `source_offset`/`source_size`. This unifies parsed trees (whose layout walk reproduces
  their on-disk offsets — the byte-exact invariant) and synthesized trees (whose offsets
  exist only in a predicted layout) under one code path.
- **Immutability precondition (guarded assumption).** Captured offsets are valid because
  the *same immutable tree instance* flows through `collect` and serialization. If a
  preceding box's size changed between capture and serialize, offsets would go stale; our
  pipeline never does this. Stated as a precondition, not defended at runtime.
- **Acyclic, shallow trees.** Segment trees are acyclic (immutable construction) and
  shallow in practice (depth = number of chained ops, typically ≤3). `O(depth)`
  resolution. No cycle detection.
- **Scope is recursive *byte* resolution only.** The lazy/streamable `samples/2` seam
  (Pillar 2) is **deferred to Phase 9** — see "Scope boundary" below. Concurrent parsing
  (Pillar 3) is discarded. Network providers (Pillar 4) are not built; the resolver shape
  leaves room for a future pluggable provider but adds no networking here.

## The layout-determinism invariant (the heart of this phase)

A synthesized inner tree stamped its sample offsets (`stco`/`co64`) against a **predicted
layout** computed at synthesis time. To map a sample's absolute offset back to physical
bytes, the resolver must agree with that prediction to the byte. A single-byte disagreement
(an `stco`→`co64` promotion, an mdat compact↔large header flip, a different header size)
shifts `target_offset − payload_start` and silently corrupts the slice.

The defense is structural, not vigilant: **one walk, one `Layout.box_size/1`, offsets
captured once.** By recording `payload_start` during the layout walk instead of
recomputing it in the resolver, the invariant collapses from "two computations must agree"
to "one computation, captured once." There is no second code path to keep in sync.

## Components

### `MdatSource` (rewritten resolver)

- **`collect/1`** changes return shape from `[%Box{}]` (a plain filter) to a list of
  records `%{box: mdat_box, payload_start: abs, payload_size: len}`. It walks the full
  top-level box list accumulating `current_offset` via `Layout.box_size/1` (this is
  `Layout.top_level_layout/1` specialized to mdats), and for each `mdat` records
  `payload_start = offset + Layout.header_size(mdat)` and
  `payload_size = box_size − header_size`. No dependence on `source_offset`.
- **`segment/3`** — `segment(collected, offset, length)`:
  1. Find the record whose span `[payload_start, payload_start + payload_size)` contains
     `offset` (else raise — unchanged error semantics).
  2. `relative = offset − payload_start`.
  3. Resolve `relative .. relative+length` against that mdat's `data`:
     - `%FileSlice{path: p}` (a whole-file/lazy mdat) → slice directly as today:
       `%FileSlice{path: p, offset: offset, length: length}`, since for such an mdat the
       captured `payload_start` reproduces the on-disk payload start and `offset` is the
       on-disk byte position.
     - `binary` → `binary_part(bin, relative, length)`.
     - `[segment]` (the previously-raising case) → walk parts accumulating their byte
       lengths (`Layout.box_size`-consistent: `FileSlice.length`, `byte_size(binary)`, or
       recursive sum of a nested list) to find the part(s) covering the range. A part that
       is itself a `[segment]` list → **recurse** into `segment`-style resolution. The
       result is a single `binary`/`FileSlice` when the range falls in one leaf part, or a
       (possibly nested) segment list when it spans several.
- The "cannot read from a segment-list mdat" raise (mdat_source.ex:29-30) is **removed** —
  that path now resolves recursively.
- Callers `Extract`/`Trim`/`Concat` are updated for the new `collect/1` record shape. Their
  compatibility check "raise if input mdat is already a segment list" is **dropped** (it
  becomes a supported case), which is what enables chaining.

### `Layout.box_size/1` (one new clause)

Add a clause so a segment-list element that is itself a list sums recursively. Today the
list clause (layout.ex:26-34) maps `FileSlice | binary`; it gains a `parts when is_list`
recursion so `box_size`/segment-length math is correct for nested trees. Factor the
part-length sum into a shared `segments_size/1` used by both `Layout` and `MdatSource` so
the two never disagree on what a segment list weighs.

### `Serializer` (recurse through nested parts)

- **`materialize_box/1`** (serializer.ex:18-28): the `is_list(parts)` clause gains a
  nested-list arm that flattens recursively (read `FileSlice`, pass through `binary`,
  recurse into nested list) before `IO.iodata_to_binary/1`.
- **`stream_payload/1`** (serializer.ex:110-115): the `is_list(parts)` clause gains a
  nested-list arm that streams recursively in order — preserving the disk→disk, never-fully-
  materialized guarantee for arbitrarily nested trees. (`stream/3` already writes to any raw
  `io_device`; streaming to a socket/S3 sink is a *follow-on*, not part of this PR.)
- `to_iodata/1`'s raise-on-segment-list stays (segment lists are still resolved via
  `serialize`/`write`, not raw `to_iodata`).

### `ISOMedia.collect_slice_paths/1` (overwrite guard, recurse)

The overwrite guard (iso_media.ex:108-113) must see `FileSlice` paths nested inside nested
segment lists, or the Phase-4-class "corrupt the source on write-to-same-path" bug returns
for chained trees. Add a nested-list recursion arm. This is a correctness fix, not a
nicety — it gets its own regression test.

## Data flow (the `trim |> concat |> trim` case)

1. `trim(A)` → tree T1 with a segment-list `mdat` referencing A's file (FileSlices) +
   any synthesized bytes. T1's `stco` offsets are absolute in T1's predicted layout.
2. `concat([T1, T2])` reads samples from T1 via `samples/2`/`SampleTable` (offsets absolute
   in T1's layout), and resolves each sample's bytes via `MdatSource.segment(collect(T1), …)`.
   `collect(T1)` reproduces T1's predicted layout exactly, so the relative-offset math lands
   on the right (possibly nested) part. The concat output T3's `mdat` segment list now
   contains, among its parts, **segments that are themselves T1's segment lists** — i.e. a
   nested tree.
3. `trim(T3)` reads from T3 the same way; resolution recurses one level deeper where it hits
   T1's nested list. `O(depth)`.
4. `serialize(T3)` / `write(path, T3)` materializes or streams the whole nested tree; bytes
   are identical to having written T1 to disk, re-read it, concatenated, written, re-read,
   trimmed.

## Testing

- **Headline (proves the engine):** build `trim |> concat |> trim` two ways — (a) fully
  in-memory nested tree, (b) disk write+re-read between every stage — and assert the final
  serialized bytes are **byte-identical**. Assert additionally that every sample in the
  final track table resolves to the correct physical bytes (compare each sample's resolved
  slice against the disk-pipeline's bytes at the same sample). Run against `sample_av.mp4`.
- **Layout-drift teeth:** a fixture/edit that forces an `stco`→`co64` promotion *inside* an
  inner synthesized tree, then chains it; the test must fail if the resolver ever recomputes
  layout differently than capture (mutation/fault injection: perturb a captured
  `payload_start` by one byte → corrupt slice detected).
- **Depth ≥ 3:** chain three operations to exercise two levels of nesting; assert identity.
- **Lazy == eager:** the whole chain with lazy-parsed inputs equals the eager path.
- **Overwrite guard:** writing a chained (nested-FileSlice) tree to one of its own source
  paths raises — regression for the recursive `collect_slice_paths`.
- **Unit:** `MdatSource.segment/3` on hand-built nested segment lists (range within one
  part, range spanning parts, range crossing a nested boundary).

## Public API

No new public function is required for chaining — `trim`/`concat`/`extract_track` outputs
simply become valid inputs to one another, and `serialize`/`write` handle nested trees.
(`stream`-to-arbitrary-`io_device` for socket/S3 sinks is noted as a natural follow-on but
is **not** in this phase.)

## Scope boundary (explicit deferrals)

- **Lazy/streamable `samples/2` seam (Pillar 2 API seam): DEFERRED to Phase 9.**
  *Recommendation for review:* recursive byte-resolution and index-memory-scale are
  disjoint surfaces with disjoint tests; the streamable-samples seam's real motivation is
  the ~800k-sample **fragmented** index of Phase 9, where it can be built and tested
  against a large index. Keeping Phase 8 to byte resolution honors the tight-PR / isolated-
  debugging-coordinate-space rationale that motivated splitting this phase out at all.
  **Open question for the reviewer:** keep this deferral, or fold the samples seam in here?
- **Packed-binary index representation (Pillar 2 optimization):** deferred until measured.
- **Concurrent parsing (Pillar 3):** discarded (parsing is I/O-bound; BEAM gives
  per-request concurrency for free).
- **Network providers / push streaming (Pillar 4):** not built. The resolver's shape leaves
  room for a future pluggable source provider, but no HTTP/S3/Membrane code is added.
- **Edit-list merging across a splice** (the concat caveat) is unchanged and still out of
  scope.

## Risks

- **Offset capture vs. serialization drift** — neutralized by the capture-once design;
  guarded by the layout-drift teeth test. This is *the* risk; everything else is mechanical.
- **`collect/1` contract change** ripples to `Extract`/`Trim`/`Concat`. Bounded, all
  in-repo callers; covered by their existing real-fixture round-trip suites.
- **Deep/odd nesting** — acyclic, shallow assumption is stated, not enforced; pathological
  inputs are not a real-world concern for a functional pipeline.
