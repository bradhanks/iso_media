# Unify Progressive `[ftyp, moov, mdat]` Assembly — Design

**Date:** 2026-06-09
**Status:** Proposed
**Source idea:** Design-review smear map — "#1: the progressive `[ftyp, moov, mdat]`
offset-baking skeleton is duplicated 3× (Extract / Trim / ProgressiveBuild)" and "#2:
Trim and ProgressiveBuild share ~70% of their moov/trak rebuild (`set_*_duration`, `opt`,
`sync_*`, the stbl-table assembly)." This spec consolidates both: #1 is the skeleton, #2
is the per-trak rebuild it calls. They are one refactor.

## 1. Context & motivation

Three functions build a progressive movie by repacking sample bytes into a fresh
contiguous `mdat` and baking absolute chunk offsets for the new layout:

- `Extract.extract_track/2` (`extract.ex`) — one track, tables copied, `stco` swapped.
- `Trim.trim/3` (`trim.ex`) — every track, tables rebuilt from a kept-sample subset, `edts` added.
- `ProgressiveBuild.assemble/4` (`progressive_build.ex`) — N inputs joined per track
  (reached by `Concat` and `Defragment`).

All three run the **identical offset-baking skeleton**, and Trim and ProgressiveBuild
additionally share the **identical per-trak table rebuild**. The skeleton, today, in each:

```
total          = Σ run lengths
mdat_mode      = Box.size_mode_for_body(total);  mdat_header = Box.header_base(mdat_mode)
bound          = box_size(ftyp) + box_size(moov_with_co64_dummy_offsets) + 16 + total
co_kind        = ChunkOffset.kind_for(bound)
moov0          = build_moov(dummy_offsets, co_kind)            # size it
mdat_payload_start = box_size(ftyp) + box_size(moov0) + mdat_header
chunk_offsets  = bake offsets from mdat_payload_start over the runs in byte-layout order
moov_final     = build_moov(real_offsets, co_kind)
segments       = MdatSource.segment(mdats, off, len) per run, byte-layout order
mdat           = MdatSource.synthesized_mdat(segments, mdat_mode, mdat_payload_start)
[ftyp, moov_final, mdat]
```

Concretely it appears at `extract.ex:65-84`, `trim.ex:53-93`, and
`progressive_build.ex:44-89` — three byte-for-byte-equivalent copies of subtle
offset-baking logic. Every fix or invariant (the `+16` co64 upper bound, the two-pass
sizing, the interleave-vs-logical ordering split) has to be made in three places.

The **#2 duplication** sits inside the Trim and ProgressiveBuild `build_moov` closures:
`assemble_moov` + `build_trimmed_trak`/`build_joined_trak` both assemble the same
`[stsd, stts, (ctts), stsc, stsz, (stss), stco]` stbl, and both define their own
`set_mvhd_duration` / `set_tkhd_duration` / `set_mdhd_duration` (decode→put→encode),
`opt/1`, and sync-sample position extraction (`trim.ex:224-266`,
`progressive_build.ex:175-210`).

**Invariants (unchanged):** byte-for-byte round-trip, zero runtime dependencies, and the
in-memory composition guarantee. This is a **behavior-preserving** refactor — the output
trees must be byte-identical to today's for every input.

## 2. Goals & non-goals

### Goals
- One implementation of the offset-baking skeleton, called by all three builders.
- One implementation of the per-trak stbl/duration rebuild, called by Trim and ProgressiveBuild.
- **Zero output change**: `extract_track`/`trim`/`concat`/`defragment` produce byte-identical
  trees before and after, proven against the existing suites.

### Non-goals
- **No new capability.** Not changing what gets produced, only how it is assembled.
- **`Fragment`** (`moof`+`mdat`, moof-relative `trun` offsets) is *not* progressive and is
  untouched.
- **Sample-level offset semantics** are unchanged — we still bake offsets for a contiguous
  repack; `Offsets`/`synthesized_mdat` are reused as-is, not modified.

## 3. The seam: what varies vs what is shared

Everything in the skeleton is shared. Only **two things vary** between the three callers,
and they become the parameters of the shared assembler:

1. **The run plan** — the list of chunk-runs to lay out. Each run is:
   ```elixir
   %{track_index: non_neg_integer(),   # which output trak (0-based)
     order_key:   term(),              # sort key for this run within its track's stco
     source:      MdatSource records,  # where the bytes live (for segment/3)
     offset:      non_neg_integer(),   # absolute source offset of the run
     length:      non_neg_integer()}   # run byte length
   ```
   - Extract: one run per source chunk of the single track; `order_key = chunk_index`.
   - Trim: one run per kept chunk per track; `order_key = chunk_index`.
   - ProgressiveBuild: one run per `{input, chunk}` per track; `order_key = {input_i, chunk_i}`.

2. **The moov builder** — a closure `(offsets_by_track, co_kind) -> moov_box` that produces
   the `moov` given the baked per-track offset lists and the chosen table kind.
   - Extract: take the single trak, replace its `stco`/`co64` with `offsets_by_track[0]`.
   - Trim: rebuild each trak's stbl from its kept samples + add `edts`.
   - ProgressiveBuild: rebuild each trak's stbl from its joined-input samples.

The assembler owns the **interleave-vs-logical** split that all three get right today:
runs are laid out (and segments emitted) in **byte order** (sorted by source `offset`, to
preserve A/V interleave), but each track's `stco` lists its runs in **logical order**
(sorted by `order_key`). This subtle ordering is the most error-prone part and the biggest
win from having it once.

## 4. Component A (#1): `ProgressiveBuild.bake/3`

`ProgressiveBuild` is promoted from "the N-input joiner" to **the progressive assembler**.
Its current `assemble/4` becomes a thin run-plan+builder constructor over the new core.

```elixir
@doc """
Bake a progressive `[ftyp, moov, mdat]` from a run plan and a moov builder.

`runs` is the chunk-run plan (see §3). `moov_builder.(offsets_by_track, co_kind)` returns
the `moov` for the given baked per-track offset lists (`%{track_index => [offset]}`) and
chosen `co_kind`. The byte layout preserves interleave (runs sorted by source offset); each
track's offsets are listed in `order_key` order.
"""
@spec bake(Box.t(), [run], (%{non_neg_integer() => [non_neg_integer()]}, :stco | :co64 -> Box.t())) ::
        [Box.t()]
def bake(ftyp, runs, moov_builder) do
  layout = Enum.sort_by(runs, & &1.offset)            # byte order (interleave)
  total  = Enum.sum(Enum.map(layout, & &1.length))
  mdat_mode   = Box.size_mode_for_body(total)
  mdat_header = Box.header_base(mdat_mode)

  dummy   = zero_offsets_by_track(runs)
  bound   = Layout.box_size(ftyp) + Layout.box_size(moov_builder.(dummy, :co64)) + 16 + total
  co_kind = ChunkOffset.kind_for(bound)

  moov0 = moov_builder.(dummy, co_kind)
  mdat_payload_start = Layout.box_size(ftyp) + Layout.box_size(moov0) + mdat_header

  {placed, _} =
    Enum.map_reduce(layout, mdat_payload_start, fn r, pos -> {Map.put(r, :at, pos), pos + r.length} end)

  offsets_by_track = group_offsets(placed)             # by track_index, sorted by order_key
  moov  = moov_builder.(offsets_by_track, co_kind)
  segs  = Enum.map(placed, fn r -> MdatSource.segment(r.source, r.offset, r.length) end)
  mdat  = MdatSource.synthesized_mdat(segs, mdat_mode, mdat_payload_start)
  [ftyp, moov, mdat]
end
```

- `zero_offsets_by_track/1`: `%{ti => List.duplicate(0, run_count)}` for every track present.
- `group_offsets/1`: group `placed` by `track_index`, sort each group by `order_key`, map to `:at`.
- The `+16` co64 upper bound, two-pass sizing, and `synthesized_mdat` basis stamp are exactly
  today's logic, now in one place.

## 5. Component B (#2): shared per-trak rebuild

The Trim and ProgressiveBuild moov builders both call a shared trak-table assembler. Two
homes, by ownership:

**`ISOMedia.SampleTable.build_stbl/4`** (it already owns `build_stts`/`build_stsz`/… ):
```elixir
@doc "Assemble an stbl child list from a sample set, run lengths, and a prepared stco/co64 box."
def build_stbl(stsd, samples, run_lengths, stco_box) do
  stts = build_stts(Enum.map(samples, & &1.duration))
  ctts = build_ctts(Enum.map(samples, &(&1.pts - &1.dts)))
  stsz = build_stsz(Enum.map(samples, & &1.size))
  stsc = build_stsc(run_lengths)
  stss = if Enum.all?(samples, & &1.sync?), do: nil, else: build_stss(sync_positions(samples))
  [stsd, stts] ++ opt(ctts) ++ [stsc, stsz] ++ opt(stss) ++ [stco_box]
end
```
(absorbing `sync_positions/1` and `opt/1`, currently duplicated in both modules).

**`ISOMedia.TrackBuild`** (new, tiny) — the duration setters that span the `mvhd`/`tkhd`/`mdhd`
typed views (don't belong in `SampleTable`):
```elixir
def put_movie_duration(mvhd, d), do: MovieHeader.encode(%{MovieHeader.decode(mvhd) | duration: d})
def put_track_duration(tkhd, d), do: TrackHeader.encode(%{TrackHeader.decode(tkhd) | duration: d})
def put_media_duration(mdhd, d), do: MediaHeader.encode(%{MediaHeader.decode(mdhd) | duration: d})
```
(absorbing the six identical `set_*_duration` helpers across Trim and ProgressiveBuild).

Trim's builder = `build_stbl` + `put_*_duration` + `put_edts` (its edts-on-lead logic stays
in Trim — it is Trim-specific). ProgressiveBuild's builder = `build_stbl` + `put_*_duration`,
no edts. Extract's builder uses neither (it keeps the original tables and only swaps `stco`);
it benefits from §4 only.

## 6. Per-module after-state

| Module | Builds run plan from | moov_builder | Loses |
|--------|----------------------|--------------|-------|
| `Extract` | single track's chunks | swap `stco` on the one trak | its own skeleton (`extract.ex:65-84`) |
| `Trim` | per-track selections | `build_stbl` + durations + `edts` | skeleton + `set_*_duration`/`opt`/`sync`/stbl assembly |
| `ProgressiveBuild` | per-`{input,track}` runs | `build_stbl` + durations | the `assemble/4` skeleton body (now `bake/3`) |
| `Concat`/`Defragment` | unchanged | — | nothing (still call `ProgressiveBuild`) |

## 7. Correctness argument

The refactor is a pure **extract-method**: each of the three current bodies is rewritten as
"build run plan → call `bake/3` with a builder closure", where the closure is the module's
existing `build_moov` logic. Because `bake/3` is the verbatim skeleton and the closures are
the verbatim builders, the produced tree is structurally identical. The two ordering rules
(`layout` by source offset, `group_offsets` by `order_key`) reproduce exactly what each module
does today (`Enum.sort_by(& &1.offset)` for segments; `Enum.sort_by(& &1.chunk_i)` /
`&{&1.input_i, &1.chunk_i}` for the stco). No offset arithmetic changes.

The one thing to verify carefully is that Extract's **single-list** offset baking equals the
**per-track map** form: Extract today bakes one flat `chunk_offsets` list; under the seam it is
the degenerate one-track `offsets_by_track[0]`. Same values, same order.

## 8. Testing

This is behavior-preserving, so the bar is **byte-identical output**, not new behavior:

- **Golden equivalence** — for every fixture, assert the new `extract_track`/`trim`/`concat`/
  `defragment` produce `serialize`-byte-identical trees to a baseline captured from the current
  implementation (snapshot the current outputs to fixtures first, then refactor, then diff).
- **Existing suites unchanged** — all of `extract_test`, `extract_property_test`, `trim_test`,
  `trim_property_test`, `concat_test`, `concat_property_test`, `defragment_test`, and
  `offsets_property_test` must pass with no edits. These already prove sample DTS/PTS/size/sync
  and chunk-offset correctness; they are the real safety net.
- **`co64` path** — a property/unit case forcing `ChunkOffset.kind_for` to `:co64` (lowered
  threshold or large offsets) through all three callers, asserting `bake/3` picks `co64`.
- **Interleave** — the existing A/V interleave assertions in `trim`/`concat` cover the
  `layout`-vs-`order_key` split; confirm they still hold.
- **In-memory composition** — `trim |> concat |> faststart` etc. stay byte-identical to a
  disk-round-tripped baseline (the existing composition tests).

Because the full `mix test`/StreamData property suite is the safety net here, this refactor
should land only when that suite can be run — the byte-exact harness alone is insufficient to
catch a subtle offset regression.

## 9. Module touch list

- **New:** `ProgressiveBuild.bake/3` (the skeleton) and its private `zero_offsets_by_track/1`,
  `group_offsets/1`; `SampleTable.build_stbl/4` (+ now-shared `sync_positions/1`, `opt/1`);
  `ISOMedia.TrackBuild` with `put_movie_duration/2`, `put_track_duration/2`, `put_media_duration/2`.
- **Edit:** `Extract.extract_track/2` → run plan + stco-swap builder + `bake/3` (drop its
  skeleton + local `offset_box`/baking). `Trim.trim/3` → run plan + builder + `bake/3` (drop
  skeleton, `set_*_duration`, `opt`, `sync_box`, stbl assembly; keep `select_track`, `edts_for`,
  `put_edts`). `ProgressiveBuild.assemble/4` → run plan + builder over `bake/3` (drop skeleton,
  `set_*_duration`, `opt`, `sync_positions`, stbl assembly).
- **Unchanged:** `Concat`, `Defragment` (still call `ProgressiveBuild.assemble/4`); `Offsets`,
  `MdatSource.synthesized_mdat/3`, `Fragment`.
- **Tests:** golden snapshot fixtures; the listed property/unit suites pass unedited.
- **Docs:** CLAUDE.md `ProgressiveBuild`/`Trim`/`Extract`/`SampleTable` notes; add `TrackBuild`.
