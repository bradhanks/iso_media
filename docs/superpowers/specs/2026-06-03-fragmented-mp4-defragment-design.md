# Design: fragmented MP4 (fMP4) indexing & defragmentation

**Date:** 2026-06-03
**Status:** Draft (design phase)
**Builds on:** Phases 1-8 (box surgery, faststart, lazy payloads, sample index/extraction, trim, frame-accurate trim, concat, recursive virtual I/O).

## Goal

Read fragmented MP4 (`moof`/`traf`/`trun`, the native format of DASH/HLS/CMAF) into the
**same eager `[%ISOMedia.Sample{}]`** the progressive indexer produces, and **defragment**
a fragmented tree into a standard progressive MP4 (`[ftyp, moov, mdat]` with populated
`stbl` tables) — a pure metadata repack with **zero transcoding**, memory-safe via the
Phase 8 recursive segment-list `mdat`.

Two public entry points:
- `ISOMedia.samples/2` gains the ability to index a fragmented track (transparently — same
  return shape).
- `ISOMedia.defragment/1` — `[ftyp, moov, moof, mdat, …] → [ftyp, moov, mdat]` progressive.

## Decisions (from brainstorming)

- **Eager output, no streaming seam.** The fMP4 indexer returns a fully materialized
  `[%Sample{}]`, identical in shape to progressive indexing. The lazy `stream_samples/2`
  seam (Pillar 2) is **out of scope** — it is cross-cutting (touches all sample consumers)
  and, decisively, **defragment cannot benefit from it**: a metadata-complete progressive
  `moov` requires the whole sample set resident to size `stsz`/`stsc`/`stco`. Defragment is
  inherently O(total samples) in metadata RAM regardless of input streaming. Streaming
  belongs to a later streaming-*transform* phase. Packed-binary index representation is the
  lever for the 800k-sample RAM concern, also deferred.
- **`defragment/1` takes one flat box list.** A parsed file is natively
  `[%Box{}]`. A multiplexed capture parses to `[ftyp, moov, moof, mdat, moof, mdat, …]`
  directly; split DASH/HLS segments unify by plain list concatenation:
  `defragment(init ++ seg1 ++ seg2)`. No wrapper/multi-arg signature.
- **`chunk_index` = per-`trun` counter (1-based, per track).** Each `trun` is a contiguous
  single-track run inside one fragment's `mdat` — the physical equivalent of a progressive
  chunk. This makes `MdatSource`'s existing `Enum.chunk_by(& &1.chunk_index)` resolve each
  run to one contiguous byte span with **zero engine changes**.
- **Decode-only typed views.** New fMP4 boxes need `decode/1` only; defragment emits
  *progressive* tables via the existing `SampleTable.build_*` encoders + `ChunkOffset`.
- **Out of scope (raise gracefully):** progressive→fMP4 (the reverse direction); encrypted
  fMP4 (`senc`/`saiz`/`saio`, CMAF-CENC); out-of-order fragment arrival (fragments are
  assumed in temporal order); fragments addressed by an absolute `base-data-offset` that
  does not resolve tree-locally (see invariant).

## The tree-local offset invariant (the heart of correctness)

fMP4 sample bytes are addressed either **moof-relative** (`tfhd` flag `0x020000`
default-base-is-moof — the CMAF norm) or via an explicit `tfhd` `base-data-offset` that is
absolute **in the fragment's original file**. The concatenation trick
(`init ++ seg1 ++ seg2`) only works if offsets are resolved **in the coordinate space of
the tree handed to the indexer**, never against any original file boundary.

So the indexer runs a single `Layout.box_size/1` walk over the given flat box list (exactly
as `MdatSource.collect/1` does) and records each `moof`'s absolute `moof_offset` in that
tree. Per fragment:

- **default-base-is-moof:** base = `moof_offset`. With `trun` `data-offset-present`
  (`0x000001`, signed int32), the run's first sample byte is
  `sample_start = moof_offset + data_offset`; subsequent samples accumulate
  `prev_offset + prev_size`.
- The computed `sample_start` lands inside the sibling `mdat`'s payload span (the `mdat`
  follows its `moof` in the tree), so `MdatSource.segment/3` resolves it against the **same
  tree-local record map** `collect/1` produces — one source of truth, no drift.
- **Unsupported addressing → raise.** An explicit `base-data-offset` (`tfhd` `0x000001`)
  that does not resolve to a byte inside a sibling `mdat` of the same `moof`, or any mapping
  we cannot place tree-locally, raises `ArgumentError`. This isolates us from arbitrary
  offset leakage rather than silently mis-slicing.

This mirrors Phase 8's layout-determinism invariant: offsets are computed once, from the
tree's own `Layout`, shared by indexer and resolver.

## Box flag registries & cascade solver

### `tfhd` (Track Fragment Header) flags
`0x000001` base-data-offset-present (64-bit) · `0x000002` sample-description-index-present ·
`0x000008` default-sample-duration-present · `0x000010` default-sample-size-present ·
`0x000020` default-sample-flags-present · `0x020000` default-base-is-moof.

### `trun` (Track Run) flags
`0x000001` data-offset-present (signed int32) · `0x000004` first-sample-flags-present ·
`0x000100` sample-duration-present · `0x000200` sample-size-present ·
`0x000400` sample-flags-present · `0x000800` sample-composition-time-offsets-present
(signed when `trun.version == 1`).

### Cascade priority (per sample field)
- **Duration:** `trun` entry → `tfhd` default_sample_duration → `trex` default_sample_duration → 0.
- **Size:** `trun` entry → `tfhd` default_sample_size → `trex` default_sample_size → 0.
- **Flags (→ `sync?`):** `trun` entry flags → `trun` first_sample_flags (sample 1 only) →
  `tfhd` default_sample_flags → `trex` default_sample_flags. `sync?` is the negation of the
  `sample_is_non_sync_sample` bit (bit 16 of the 32-bit sample-flags field).
- **Composition offset (`pts − dts`):** `trun` entry composition_time_offset (signed int32
  when `trun.version == 1`, else unsigned) → 0.
- **`dts`:** `tfdt` `baseMediaDecodeTime` for the fragment's first sample, then cumulative
  by duration. `pts = dts + composition_offset`.

## Components

- **New decoders** (`lib/iso_media/boxes/`), each `decode(%Box{}) → struct` via `FullBox.parse`:
  - `TrackExtends` (`trex`): `track_id`, `default_sample_description_index`,
    `default_sample_duration`, `default_sample_size`, `default_sample_flags`.
  - `TrackFragmentHeader` (`tfhd`): `track_id` + flag-gated optionals
    (`base_data_offset`, `sample_description_index`, `default_sample_duration`,
    `default_sample_size`, `default_sample_flags`) + `default_base_is_moof?`.
  - `TrackFragmentDecodeTime` (`tfdt`): `base_media_decode_time` (v0 32-bit / v1 64-bit).
  - `TrackRun` (`trun`): `version`, `sample_count`, optional `data_offset`,
    optional `first_sample_flags`, and a per-sample list of
    `{duration?, size?, flags?, composition_offset?}` (only the flag-present fields parsed).
- **`ISOMedia.FragmentIndex`** (`lib/iso_media/fragment_index.ex`): the cascade solver +
  indexer. Input: a flat box list. (1) Parse the init `moov`'s `mvex`/`trex` into per-track
  defaults. (2) `Layout` walk to stamp each `moof_offset`. (3) For each `moof`/`traf`, run
  the cascade to emit `%Sample{}`s with tree-local `offset`, per-`trun` `chunk_index`, `dts`
  from `tfdt`, `sync?` from flags. Output: `%{track_id => [%Sample{}]}` (or per-track on
  request). Raises on encrypted / unsupported-addressing fragments.
- **`ISOMedia.samples/2`** (dispatch): the routing lives here, not in `SampleTable.build/1`
  — fMP4 samples come from `moof`/`traf` boxes that are **siblings of `moov`**, outside the
  `trak`, so the decision needs the whole tree. `samples/2` calls
  `FragmentIndex.fragmented?(boxes)` (tree has `mvex` + at least one `moof`); if fragmented,
  route to `FragmentIndex` for the `track_id`; otherwise `SampleTable.build(trak)` as today.
  `SampleTable.build/1` is unchanged.
- **`ISOMedia.Defragment`** (`lib/iso_media/defragment.ex`): `defragment/1`. For each track:
  take the init `trak` skeleton (`tkhd`/`mdhd`/`hdlr`/`stsd`, empty `stbl`), populate `stbl`
  from the track's `[%Sample{}]` via existing `build_stts/build_stsz/build_ctts/build_stss/
  build_stsc` + `ChunkOffset`; rebuild the `mdat` as an interleave-preserving segment list
  (runs from all tracks sorted by original `offset` for physical layout, **logical**
  `{track, chunk}` order restored before building each track's `stco` — the Trim/Concat
  pattern); update `mvhd`/`tkhd`/`mdhd` durations; drop `mvex` and all `moof`. Emit
  `[ftyp, moov, mdat]`. Reuses `BoxPath` and `MdatSource`.
- **Exposed as** `ISOMedia.samples/2` (transparent) and `ISOMedia.defragment/1`.

## Data flow (defragment)

`read(frag.mp4)` → `[ftyp, moov(empty stbl, mvex), moof, mdat, moof, mdat, …]` →
`FragmentIndex` (tree-local offsets, cascade) → per-track `[%Sample{}]` → progressive `stbl`
tables + segment-list `mdat` (via `MdatSource.segment/3` into each fragment's `mdat`) →
`[ftyp, moov(populated), mdat]` → `serialize`/`write`. Because the `mdat` is a Phase 8
segment list referencing the fragments' bytes (binary or `FileSlice`), defragment is
memory-safe and never copies media through the heap unnecessarily.

## Testing

- **Fixture:** add `test/fixtures/sample_frag.mp4` via
  `ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 -f lavfi -i sine=frequency=440:duration=1 -pix_fmt yuv420p -c:a aac -shortest -movflags frag_keyframe+empty_moov+default_base_moof sample_frag.mp4`
  (multi-track, default-base-is-moof). Document in fixtures README.
- **Headline equivalence:** `defragment(read(frag))` → progressive tree whose `samples/2`
  index equals the original `FragmentIndex` of `frag` field-for-field
  (`dts`/`pts`/`size`/`sync?`/`offset`-resolved-bytes) for every track. The resolved sample
  **bytes** must match between the fragmented source and the defragmented output.
- **Round-trippable output:** `serialize(defragment(...))` parses back and re-indexes
  identically; output passes the existing progressive invariants.
- **Cascade unit tests:** hand-built `trun`/`tfhd`/`trex` combinations exercising each
  fallback rung (trun→tfhd→trex→0), `first_sample_flags`, signed v1 composition offsets,
  and `sync?` bit extraction.
- **Multi-track:** video + audio fragments interleaved; interleave preserved in the output
  `mdat`; per-track `stco` in logical order.
- **lazy == eager:** `defragment` of a lazily-parsed fragmented file equals the eager path,
  byte-for-byte.
- **Graceful raises:** a fixture/synthetic with `senc`/`saiz` (encrypted) and one with an
  unsupported absolute `base-data-offset` each raise a clear `ArgumentError`.
- **Fault injection:** perturb one `trex` default / `tfdt` base / `data_offset` and assert
  the equivalence test fails (teeth).

## Scope boundary (explicit deferrals)

- Lazy `stream_samples/2` seam — deferred to a later streaming-transform phase.
- Packed-binary index representation — deferred until measured.
- Progressive→fragmented (fragmenting) — opposite direction, deferred.
- Encrypted fMP4 (CMAF-CENC) — raise.
- Out-of-order / gap fragment handling, `mfra`-driven random access — deferred.

## Risks

- **Offset addressing variety** — neutralized by the tree-local invariant + raise-on-
  unsupported; the default-base-is-moof path (the common case) is the only fully-supported
  addressing.
- **Cascade flag correctness** — the highest-density bug surface; covered by per-rung unit
  tests + the byte-equivalence headline.
- **`samples/2` dispatch** — distinguishing a fragmented tree from a progressive one must be
  unambiguous; `FragmentIndex.fragmented?/1` keys on `mvex` + presence of `moof`. A
  progressive file with an unusually empty track must not be misrouted; covered by tests for
  both shapes.
