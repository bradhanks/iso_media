# Design: chunk-offset rewriting + faststart

**Date:** 2026-05-31
**Status:** Approved (design phase)
**Builds on:** `2026-05-31-iso-media-box-surgery-design.md` (Phase 1, lossless box surgery)

## Goal

Make box rearrangement *safe* by recomputing the absolute chunk-offset tables
(`stco`/`co64`) that break whenever boxes move. The marquee capability is
**faststart** — moving `moov` ahead of `mdat` so a file can begin playing before
it is fully downloaded. This is the Phase 2 explicitly deferred by the Phase 1
spec ("Smart re-serialization (auto offset fixup) is an explicit later phase").

## Scope

- **In:** `stco` (32-bit) and `co64` (64-bit) chunk-offset tables for
  progressive/standard MP4, MOV, M4A. Auto-promotion `stco`→`co64` when a
  recomputed offset exceeds 32 bits.
- **Out:** fragmented MP4 (`tfhd`/`trun`/`tfra`), HEIF `iloc`, and any
  sample-level editing (cutting/reordering samples within `mdat`). These are
  future phases.

## Core insight

A `stco`/`co64` entry is the absolute file position of a chunk's bytes, which
live inside some `mdat`. If an `mdat`'s payload bytes are unchanged and the box
has only **moved**, every chunk offset into it shifts by one uniform delta:

```
new_offset = old_offset + (new_mdat_payload_start − old_mdat_payload_start)
```

The feature therefore reduces to: determine where each `mdat` used to be, where
it is now, and shift the offsets by that delta. No sample-level understanding is
required. To know where an `mdat` *used* to be, the parser must remember it.

## Components

### `ISOMedia.Box` — new `source_offset` field
Add `source_offset` to the struct, default `nil`. The parser records the absolute
byte offset at which each box started. It is metadata only: the serializer ignores
it, so the Phase 1 byte-for-byte round-trip is unaffected, and hand-built boxes
carry `nil`. This is the only change to the core.

- `defstruct type: nil, data: nil, children: [], uuid: nil, size_mode: :compact, source_offset: nil`
- Parser threads a running absolute offset through `parse_boxes/parse_box` and
  stamps each box's `source_offset` as it is produced (top level and nested).

### `ISOMedia.Layout` — offset computation (pure)
Walks a tree and computes the absolute file offset of every box in the *current*
arrangement (the "new" positions after editing).

- `offsets(boxes) :: [%{box: %Box{}, path: [type], offset: non_neg_integer, header_size: non_neg_integer, payload_offset: non_neg_integer}]`
  (or an equivalent structure that lets callers look up a box's absolute offset and
  payload offset). Offsets are computed exactly as the serializer lays bytes out,
  honoring `size_mode`, `uuid`, and nesting.
- `header_size(box)` helper: 8 (compact) or 16 (large), +16 when `uuid`.
- `box_size(box)` helper: total serialized byte length of a box (header + uuid +
  payload/children), reused by the remap math. Must agree with the serializer.

### `ISOMedia.Boxes.ChunkOffset` — typed view for `stco`/`co64`
Follows the existing `Boxes.*` `decode/1`/`encode/1` contract.

- struct: `defstruct [:kind, :version, :flags, :offsets]` where `kind` is `:stco`
  or `:co64` and `offsets` is a list of integers.
- `decode(%Box{type: "stco"|"co64"})`: FullBox prefix, then `entry_count::32`, then
  `entry_count` entries (32-bit for `stco`, 64-bit for `co64`).
- `encode(%ChunkOffset{})`: emits `stco` or `co64` box per `kind`, regenerating
  `entry_count`.

### `ISOMedia.fix_chunk_offsets/1` — the primitive
Takes a fully-arranged tree and returns a tree with corrected `stco`/`co64`.

### `ISOMedia.faststart/1` — the marquee one-liner
`faststart(boxes)` = move `moov` to immediately after `ftyp` (and before `mdat`),
then `fix_chunk_offsets/1`. Returns the rearranged, corrected tree.

## Algorithm (`fix_chunk_offsets/1`)

1. **Original mdat ranges.** Find all top-level `mdat` boxes. For each, its
   original byte range is `[source_offset, source_offset + box_size(mdat))`
   (size derived from the box itself, since content is unchanged). Its original
   payload start is `source_offset + header_size(mdat)`.
2. **New mdat positions.** Compute `Layout.offsets/1` on the current tree to get
   each `mdat`'s new payload start.
3. **Per-mdat delta.** `delta(mdat) = new_payload_start − old_payload_start`.
4. **Remap every chunk-offset table.** For each `stbl` `stco`/`co64`, decode it,
   and for each chunk offset `O`: find the `mdat` whose **original** range contains
   `O` and add that mdat's delta. (Multiple `mdat`s are handled per-range.)
5. **co64 promotion.** If any remapped offset for a table exceeds `0xFFFFFFFF`,
   convert that `stco` to a `co64`. Promotion grows `moov`; if `moov` precedes the
   affected `mdat`, that shifts offsets again, so **recompute layout and repeat
   from step 2 until offsets are stable** (a fixpoint). Convergence is bounded
   (≤ a small constant; cap iterations and raise if exceeded). The common <4 GB
   case promotes nothing and completes in a single pass.
6. Write the corrected `stco`/`co64` boxes back into the tree (via existing
   `Box.update`).

## Error handling & explicit assumptions

`mdat` payloads must be byte-identical to what was parsed (no sample editing in
this phase). Guards:

- An `mdat` with `source_offset == nil` (freshly synthesized), or whose current
  `box_size` differs from its size at parse time, means the data changed or is not
  traceable → **raise `ArgumentError`** with a message pointing at the
  sample-editing limitation. (Consistent with `Box.insert/4` raising on misuse.)
- A chunk offset that falls within no `mdat`'s original range is left unchanged
  (rare — e.g. self-contained sample data); the count of such offsets is reported
  in the raised message only if it would produce an unresolvable file, otherwise
  left as-is silently is NOT acceptable — instead collect them and raise if any
  exist, since silently leaving them risks a broken file. (Decision: **raise** on
  any unmappable chunk offset.)
- `faststart/1` on a tree with no `moov` or no `mdat` → return the tree unchanged
  (nothing to do), since there are no offsets to break.

Both `fix_chunk_offsets/1` and `faststart/1` return the plain tree (raising on the
misuse cases above), matching the editing API style.

## Testing

### Property-based testing (primary — required to be robust)
A `StreamData` generator produces minimal-but-valid MP4-like **box trees with
verifiable chunk data**: an `mdat` containing N chunks of distinct marker bytes,
and a `moov/trak/mdia/minf/stbl` whose `stco` lists the correct absolute offsets
of those chunks (plus the minimal `stsd`/`stts`/`stsc`/`stsz` needed to be
structurally valid). The generator serializes this to a binary and parses it back
so `source_offset` is populated, yielding a realistic input.

Properties:

1. **Chunk resolution invariant (the central property).** For a generated file,
   apply a *random sequence of structural edits* (insert/remove/resize `free`
   boxes before/after `mdat`, and/or `faststart`), run `fix_chunk_offsets`,
   serialize, re-parse, and assert: **for every chunk, the bytes at its (fixed)
   `stco`/`co64` offset equal that chunk's original marker bytes.** This proves
   chunks still resolve no matter how boxes moved.
2. **No-op invariant.** `fix_chunk_offsets(parse(file)) |> serialize == file` when
   the tree is unedited (nothing moved ⇒ zero deltas ⇒ identical bytes).
3. **Idempotence.** `fix_chunk_offsets(fix_chunk_offsets(t)) == fix_chunk_offsets(t)`.
4. **faststart invariant.** After `faststart`, re-parsed tree has `moov` before
   `mdat`, and property (1) holds for the faststarted file.
5. **Round-trip preserved.** `parse(file) |> serialize == file` still holds with
   the new `source_offset` field present (it must not leak into output).

### Unit tests
- `Layout.offsets/1` and `box_size`/`header_size` against hand-computed trees
  (compact, large, uuid, nested).
- `Boxes.ChunkOffset` decode/encode round-trip for both `stco` and `co64`.
- `stco`→`co64` promotion at the 4 GB boundary (synthetic offsets), including the
  layout-fixpoint loop.
- Guards: raise on synthesized `mdat` (no `source_offset`) and on size-changed
  `mdat`; raise on an unmappable chunk offset.

### End-to-end
- `faststart` on the real `test/fixtures/sample.mp4`: serialize, re-parse, assert
  `moov` precedes `mdat`, and independently verify every `stco` entry points at the
  correct chunk bytes by recomputing chunk positions from the new layout. If
  `ffprobe` is available, assert it reports the file as valid (skip cleanly if not).

## Project layout (new/changed files)

```
lib/iso_media.ex                       # + faststart/1, fix_chunk_offsets/1
lib/iso_media/box.ex                   # + source_offset field
lib/iso_media/parser.ex                # stamp source_offset during parse
lib/iso_media/layout.ex                # NEW: offset computation
lib/iso_media/boxes/chunk_offset.ex    # NEW: stco/co64 typed view
lib/iso_media/offsets.ex               # NEW: fix_chunk_offsets/faststart impl (or keep in iso_media.ex if small)
test/iso_media/layout_test.exs
test/iso_media/boxes/chunk_offset_test.exs
test/iso_media/offsets_test.exs
test/iso_media/offsets_property_test.exs   # the property suite above
test/support/mp4_builder.ex            # NEW: test helper that builds verifiable MP4 trees
```

## Out of scope (this phase)

- Fragmented MP4 and HEIF `iloc` offsets.
- Sample-level editing (cut/trim/reorder samples within `mdat`).
- Rewriting any offset table other than `stco`/`co64` (e.g. `saio`, `tfra`).
