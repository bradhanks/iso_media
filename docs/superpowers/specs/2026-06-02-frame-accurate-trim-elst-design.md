# Design: frame-accurate trim via edit lists (`elst`)

**Date:** 2026-06-02
**Status:** Approved (design phase)
**Builds on:** Phase 5 (time-based trim). Also Phases 1-4.

## Goal

Make `ISOMedia.trim/3` frame-accurate: the clip should *present* starting exactly at
the requested time, even though the decoded media starts a little earlier (Phase 5
snaps the start back to the preceding keyframe so the first frame can be decoded).
We do this by adding an edit list (`elst`) per track describing the presentation
window — the samples, `mdat`, and durations are unchanged.

## Background — the edit list

`elst` lives in `trak → edts → elst`. It is a FullBox listing edit segments; each
entry is `{segment_duration, media_time, media_rate_integer, media_rate_fraction}`.
The **timescale trap**: `media_time` is in the track's **media** timescale (`mdhd`),
while `segment_duration` is in the **movie** timescale (`mvhd`). `media_time = N`
tells the player to begin presentation at media-time N (skipping the leading
decoded frames); `media_time = -1` is an empty edit (gap). For a frame-accurate
trim we use a single edit with `media_time = lead`, `rate = 1.0`.

## Decisions (from brainstorming)

- **Always frame-accurate** — `trim/3` always emits the `edts`/`elst` when the snap
  produced a nonzero lead; no new option. Purely additive (correct players honor it;
  players that ignore edit lists fall back to today's Phase-5 behavior). Samples and
  all Phase-5 byte/interleave/lazy guarantees are unchanged.
- **Drop inherited edit lists** — Phase 5 re-bases the media timeline to 0, so a
  source `elst` (with offsets against the old timeline) would be wrong; we synthesize
  a fresh one and drop any existing `edts`.
- **Per-track lead** — video gets a GOP-sized lead; audio typically gets a small lead
  (the requested start usually falls fractionally between audio frames), keeping A/V
  aligned to the exact requested point.
- **v0, upgrading to v1** only when `segment_duration` or `media_time` exceeds 32 bits.

## Components

### `ISOMedia.Boxes.EditList` (new — `lib/iso_media/boxes/edit_list.ex`)
`decode/1`/`encode/1` for `elst`, following the `Boxes.*` contract.
- struct: `%EditList{version, entries: [%{segment_duration, media_time,
  rate_integer, rate_fraction}]}`.
- `decode`: FullBox prefix → `entry_count` → entries. v0: `segment_duration::32`,
  `media_time::signed-32`, `rate_integer::signed-16`, `rate_fraction::16`. v1:
  `segment_duration::64`, `media_time::signed-64`, then the two 16-bit rate fields.
- `encode`: picks v0 unless any `segment_duration`/`media_time` needs 64 bits, then
  emits accordingly; regenerates `entry_count`.

### `ISOMedia.Trim` — emit the edit list
- `select_track/2` records on its selection map:
  - `lead` = `start_ts − snap_keyframe.dts` (track timescale; the first kept sample is
    the snap keyframe, so `snap_keyframe.dts` is `hd(kept).dts`, the *original* dts).
  - `visible` = `Σ(kept durations) − lead` (track timescale; the presented media).
- `build_trimmed_trak/…` — when `lead > 0`, build an `elst` with one entry:
  `segment_duration = scale(visible, track_ts, movie_ts)`, `media_time = lead`,
  `rate_integer = 1`, `rate_fraction = 0`; wrap it in an `edts` and insert it into the
  trimmed `trak` **immediately after `tkhd`** (before `mdia`), removing any `edts`
  inherited from the source. When `lead == 0`, emit no `edts` (timeline already
  correct).
- `movie_ts` is already available in `trim/3`; thread it (and the per-track `lead`/
  `visible`) into `build_trimmed_trak`.

## Error handling

No new failure modes. `media_time`/`segment_duration` are non-negative for a forward
trim (empty/`-1` edits are out of scope). The existing trim guards (`end ≤ start`,
empty window) are unchanged.

## Testing

- **`EditList` round-trip:** v0 and v1 `decode(encode(x)) == x` and exact byte layout
  for a known entry (incl. the `media_time` signedness and the movie-vs-media
  timescale fields being carried verbatim).
- **Synthetic trim between keyframes:** a track with sparse keyframes (e.g. sync at
  samples 1 & 3); trim a window whose start falls after sample 3's keyframe but
  mid-GOP → the trimmed `trak` has `edts/elst` with `media_time == lead` (= requested
  start − snap keyframe's original dts) and `segment_duration == scale(visible, …)`;
  the kept sample bytes are still byte-identical to Phase-5 output.
- **Clean keyframe-aligned start → no `edts`:** trim starting exactly on a keyframe
  (lead 0) emits no edit list.
- **Real `sample_av.mp4` mid-GOP trim:** the video track gets an `elst` with
  `media_time` = (requested start − snap keyframe dts) in the video timescale; the
  audio track gets its own (small) `elst`; both decode via `EditList`. `mvhd.timescale`
  unchanged; sample bytes unchanged.
- **Regression:** the entire Phase 5 trim suite stays green (samples/`mdat`/durations
  unchanged); `lazy trim |> write == eager trim |> serialize` still byte-exact (the
  `elst` is in `moov`, in memory on both paths).

## Project layout (new/changed files)

```
lib/iso_media/boxes/edit_list.ex     # NEW: elst typed view (decode/encode, v0/v1)
lib/iso_media/trim.ex                # compute lead/visible; insert edts/elst per track
test/iso_media/boxes/edit_list_test.exs
test/iso_media/trim_test.exs         # + elst assertions (between-keyframes, lead==0)
test/iso_media/trim_av_test.exs      # + real-fixture elst assertions
README.md / CLAUDE.md                # note frame-accurate trim + EditList
```

## Out of scope (this phase)

- Preserving or merging source edit lists (we synthesize fresh).
- Empty edits (`media_time = -1` gaps), multiple edits per track, dwell edits, rates
  other than 1.0.
- Concatenation (next phase).
