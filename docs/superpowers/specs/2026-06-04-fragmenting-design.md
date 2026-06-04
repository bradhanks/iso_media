# Design: fragmenting (progressive → fragmented MP4)

**Date:** 2026-06-04
**Status:** Draft (design phase)
**Builds on:** Phases 1-9 (box surgery, faststart, lazy payloads, sample index/extraction, trim, frame-accurate trim, concat, recursive virtual I/O, fMP4 indexing/defragment).

## Goal

The inverse of Phase 9's `defragment/1`: take a progressive MP4 tree and emit a **single
multiplexed fragmented MP4** (`[ftyp, moov(+mvex), moof, mdat, moof, mdat, …]`) — keyframe-
aligned fragments, lossless (sample bytes copied via a Phase 8 segment-list `mdat`, no
transcoding), memory-safe. This completes the streaming round trip: the output is exactly
the shape Phase 9 *reads*, so `defragment(fragment(x))` reproduces `x`'s samples.

`ISOMedia.fragment(boxes, opts \\ [])` → `boxes`. `opts[:target_duration]` in seconds
(default `2.0`).

## Decisions (from brainstorming)

- **Single multiplexed output tree** — `fragment/1` returns one box tree, the shape Phase 9
  reads. Separate init + media segments (DASH/CMAF on-disk layout with `styp`) and manifests
  (DASH MPD / HLS) are **out of scope** (a later phase / a packaging layer).
- **Keyframe-aligned, target-duration boundaries** — a fragment can only start on a sync
  sample (so each fragment is independently decodable). The first **video** track (`hdlr`
  handler_type `vide`) drives: open a new fragment at the first keyframe whose dts ≥
  `last_boundary_dts + target` (target in that track's timescale). Boundaries are *times*;
  every track splits at those times by dts. If there is no video track, the first track
  drives with duration-only boundaries (all its samples are sync, so any split is legal).
- **All per-sample values explicit in `trun`** — duration, size, flags, and (when nonzero)
  composition_offset are written per sample; `trex` defaults are 0 and `tfhd` carries no
  sample defaults. Simplest and always round-trip-exact. `trun` default-compression (hoisting
  common values into `tfhd`/`trex`) is a deferred optimization.
- **`default-base-is-moof` addressing** — every `tfhd` sets flag `0x020000`, matching Phase
  9's reader; sample bytes are addressed moof-relative.
- **`sample_flags` encode sync** — each sample's 32-bit flags set the
  `sample_is_non_sync_sample` bit (`0x00010000`) iff the sample is not a keyframe, so Phase 9
  recovers `sync?` exactly.
- **Granularity cap (documented):** you cannot make more independently-decodable fragments
  than the source has keyframes. An audio-only or all-keyframe source fragments purely by
  duration.
- **Multiple video tracks:** the first drives; others split at its boundary times. (Picking a
  per-track boundary policy is deferred.)

## Box encoders (inverse of Phase 9 decoders)

Add `encode/1` to the existing decode-only modules (`encode(struct) → %Box{}`), mirroring the
`decode/1`/`encode/1` pattern of `EditList`/`TrackHeader`:

- `ISOMedia.Boxes.TrackExtends` — `trex` from `%{track_id, default_sample_description_index,
  default_sample_duration, default_sample_size, default_sample_flags}` (FullBox v0).
- `ISOMedia.Boxes.TrackFragmentDecodeTime` — `tfdt` (v1, 64-bit `base_media_decode_time`, to
  be safe for long media).
- `ISOMedia.Boxes.TrackFragmentHeader` — `tfhd` with `track_id` and the
  `default-base-is-moof` flag set, no optional fields (flags `0x020000`).
- `ISOMedia.Boxes.TrackRun` — `trun` with `data-offset-present` + per-sample
  `duration`/`size`/`flags` always present, and `composition-time-offsets-present` (v1, signed)
  when any sample has a nonzero composition offset. Round-trips its own `decode/1`.

The `mfhd` (Movie Fragment Header — mandatory first child of every `moof`) is a trivial
single-field FullBox (`<<0::32, sequence_number::32>>`); it is built **inline** in `Fragment`
(no typed view — Phase 9 ignores `mfhd` on read).

Each encoder is unit-tested by `decode(encode(x)) == x` (and byte-shape assertions).

## Components

- **`ISOMedia.Fragment`** (`lib/iso_media/fragment.ex`) — `fragment/2`:
  1. Find `ftyp`, `moov`, and the `trak`s. Read each track's `[%Sample{}]` via
     `ISOMedia.samples/2`, its timescale (`mdhd`), its `track_id` (`tkhd`), and its handler
     type (`hdlr`). Collect source `mdat`s via `MdatSource.collect/1`.
  2. **Choose the driver track** (first `vide`, else first track) and compute **boundary
     dts values** in the driver's timescale: greedily walk its sync samples, taking a new
     boundary at the first keyframe whose dts ≥ `last + target_ts`. The first boundary is the
     driver's first sample dts.
  3. **Partition** every track's samples into fragments by converting each boundary dts to
     the track's own timescale (`scale/3`) and slicing each track's samples into the windows
     `[b_i, b_{i+1})` by dts. A fragment is the set of per-track sample-runs sharing a window.
  4. **Build `mvex`** = one `trex` per track (defaults 0), inserted into the output `moov`
     after `mvhd`. The output `moov`'s `trak`s keep their `tkhd`/`mdhd`/`hdlr`/`stsd` but get
     an **empty `stbl`** (only `stsd` + empty `stts`/`stsc`/`stsz`/`stco` so the track parses
     as a valid no-samples progressive skeleton).
  5. For each fragment, **build a `moof`** (a `mfhd` with sequence_number + one `traf` per
     track that has samples in the window) and a sibling **`mdat`** (segment list, each
     `traf`'s run resolved from the source via `MdatSource.segment/3`, contiguous per traf).
     `data_offset`s computed two-pass (below).
  6. Emit `[ftyp, moov, moof_1, mdat_1, …]`.
- **`ISOMedia.SampleTable`** — add `empty_stbl_children/1` (or reuse `build_*` with empty
  lists) to produce the zero-sample `stbl` for the init `moov` skeleton.
- **Exposed as** `ISOMedia.fragment/2`.

## The data_offset invariant (the heart of correctness)

This is the encoding inverse of Phase 9's tree-local offset invariant, and it carries the same
hazard: each `trun.data_offset` is **moof-relative** (because `default-base-is-moof`), so it
must equal `(moof byte size) + (mdat header size) + (sum of prior trafs' run lengths in this
mdat)`. A one-byte error in the moof's own size shifts every sample.

The defense is the same two-pass shape `ProgressiveBuild` uses: **build the `moof` once with
placeholder `data_offset`s to learn its exact serialized size via `Layout.box_size/1`, then
rebuild the `trun`s with real `data_offset`s.** Because changing a `data_offset` from one
32-bit value to another does not change the `moof`'s size, the second pass is a fixpoint — one
re-encode suffices. The mdat payload starts at `moof_size + mdat_header`; traf *i*'s run starts
there plus the sum of runs `0..i-1`.

## Data flow

`read(prog.mp4)` → `[ftyp, moov, mdat]` → read per-track `[%Sample{}]` → boundary dts (driver
track) → per-track windows → for each window: `moof` (`mfhd` + `traf`/`tfhd`/`tfdt`/`trun`) +
segment-list `mdat` (source bytes via `MdatSource.segment/3`) → `[ftyp, moov(+mvex, empty
stbl), moof, mdat, …]` → `serialize`/`write`. Lossless and memory-safe (media never copied
through the heap).

## Testing

- **Fixture:** add `test/fixtures/sample_keyint.mp4` with frequent keyframes so multi-fragment
  output is reachable:
  `ffmpeg -y -f lavfi -i testsrc=duration=2:size=128x96:rate=10 -f lavfi -i sine=frequency=440:duration=2 -pix_fmt yuv420p -c:a aac -g 10 -shortest sample_keyint.mp4`
  (GOP 10 → a keyframe every 1s → multiple fragments at `target` < 1s). Document in README.
- **Encoder round-trips:** `decode(encode(x)) == x` for `trex`/`tfhd`/`tfdt`/`trun` (incl.
  signed v1 composition offsets, sync-flag bit).
- **Headline round trip:** `defragment(fragment(read(prog), target_duration: 0.5))` reproduces,
  per track, the original's `dts`/`pts`/`size`/`sync?` sequences **and resolved sample bytes**.
  Run on `sample_keyint.mp4` and `sample_av.mp4`.
- **Structural:** `fragment/2` output passes `FragmentIndex.fragmented?/1`, has ≥2 `moof`s on
  the keyint fixture, and every fragment starts on a keyframe (driver track's first sample in
  each fragment is sync).
- **Audio-only:** `fragment(read("sample.m4a"))` works (duration-only boundaries), round-trips
  through `defragment`.
- **lazy == eager:** fragmenting a lazily-read file equals the eager path, byte-for-byte.
- **Determinism teeth:** perturb a `data_offset` by one byte and assert the round-trip byte
  check fails.

## Scope boundary (explicit deferrals)

- Separate init + media segments (`styp`, self-contained `.m4s`) — follow-on phase.
- DASH MPD / HLS manifest generation — out of scope (packaging layer).
- `trun` default-compression (hoist common duration/size/flags into `tfhd`/`trex`).
- Per-track / multiple-video-track boundary policies (first video track drives).
- `sidx`/`mfra` emission (random-access indexes) — not required for a valid multiplexed fMP4.

## Risks

- **`data_offset` drift** — neutralized by the two-pass `Layout`-driven build; guarded by the
  determinism-teeth test. This is *the* risk.
- **Boundary/timescale conversion** — converting driver-track boundary dts into each track's
  timescale must use the integer `scale/3`; off-by-one windowing is covered by the headline
  round trip (timing must match exactly).
- **Init `moov` skeleton** — an empty `stbl` must still be a valid parseable progressive track;
  covered by re-parsing the output and by `defragment` (which reads `stsd` from it).
