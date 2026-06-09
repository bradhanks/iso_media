# Phase 1 — Synthesized-`mdat` Chunk Offsets (no disk round-trip)

**Feature:** `synthesized-mdat-offsets`
**Source spec:** `docs/superpowers/specs/2026-06-09-synthesized-mdat-offsets-design.md`
**Phase:** 1 of 1 (single atomic phase)
**Date:** 2026-06-08

## Phase metadata

- **Number:** 1
- **Short title:** Stamp synthesized `mdat`s with an offset basis so `fix_chunk_offsets/1`
  and `faststart/1` work in memory.

## Decomposition rationale (null hypothesis)

This feature is delivered as a **single atomic phase**. The null hypothesis holds: there is
no genuine deploy/data-safety risk that a split would reduce.

- It is a pure, in-memory metadata change in a zero-dependency binary-parsing library.
- **No migrations**, no data backfills, no deploy-ordering constraints, no external contracts
  or API consumers that must be staged.
- The deliverable is one new constructor (`MdatSource.synthesized_mdat/3`) plus three
  one-line call-site swaps that are **mutually dependent**: the swaps are inert without the
  constructor, and the constructor is dead code without the swaps. There is no intermediate
  state that is independently valuable or that lowers risk.
- `offsets.ex` / `faststart` are **unchanged by design**, so there is no risky surface to
  isolate behind a flag or sequence.

Splitting would only add ceremony without reducing risk, so one phase is correct.

## Scope boundary

**In scope:**

- New shared constructor `MdatSource.synthesized_mdat/3` that builds a segment-list `mdat`
  and stamps `source_offset`/`source_size` as the basis its chunk offsets were written against.
- Three one-line swaps replacing bare `%Box{type: "mdat", ...}` literals with the constructor:
  - `ProgressiveBuild` (`:88`, covers both Concat and Defragment).
  - `Trim` (`:92`).
  - `Extract` (`:83`).
- Result: `fix_chunk_offsets/1` and `faststart/1` accept synthesized trees without raising —
  no-op (delta 0) on an unedited synthesized tree, correct uniform remap when the `mdat` moves.
- Doc updates: ROADMAP (move the synthesized-mdat offset item from deferred to shipped) and
  CLAUDE.md notes for `MdatSource` and `Offsets`.

**Deferred (explicit non-goals, per spec §2 / §7):**

- **Sample-level offset editing** — recomputing offsets from `stsc`/`stsz` for payload
  reordering/resizing. A genuine size change still raises (`Layout.box_size(m) != source_size`).
- **Fragmented (`moof`) offsets** — `trun` data offsets are moof-relative, not `stco`; out of
  scope. `Fragment` (`moof`+`mdat` with moof-relative offsets) is **untouched**.
- The `check_integrity!` guard is **not weakened**: a stamp-less hand-built `mdat` still raises.

## Migrations

None. This is a zero-dependency Elixir library — there is no database, no schema, no migration
or backfill of any kind.

## Domain & API

Pure functions and module boundaries delivered this phase:

- **New:** `ISOMedia.MdatSource.synthesized_mdat/3`
  - Spec:
    `synthesized_mdat([binary | FileSlice.t() | list], :compact | :large | :eof, non_neg_integer()) :: Box.t()`
  - Builds `%Box{type: "mdat", data: segments, size_mode: size_mode}`, then stamps:
    - `source_offset = payload_start - Layout.header_size(box)` (the mdat **box start**).
    - `source_size = Layout.box_size(box)` (single source of truth; self-consistent with
      serialization, so `check_integrity!`'s `Layout.box_size(m) == source_size` holds by
      construction).
  - Lives in `MdatSource` alongside the existing synthesized-`mdat` resolver (`collect/1`,
    `segment/3`); the caller passes the `payload_start` it already computes, so no offset
    arithmetic is duplicated.
- **Edited call sites (one line each):**
  - `ISOMedia.ProgressiveBuild` (`:88`) — used by both `Concat` and `Defragment`.
  - `ISOMedia.Trim` (`:92`).
  - `ISOMedia.Extract` (`:83`).
  - Each already has `mdat_payload_start` in scope; only the mdat literal changes.
- **Unchanged by design:** `ISOMedia.Offsets` (`fix_chunk_offsets/1`, `faststart/1`), including
  the `stco→co64` promotion fixpoint and `rebase_mdats` idempotence machinery. With the stamp
  present, synthesized trees flow through the identical code path as parsed ones
  (`check_integrity!` passes; `mdat_ranges` derives `old_payload_start == payload_start`; delta
  is 0 when unedited, the shift when moved).

## UI & components

None. This library has no UI, LiveView, components, or templates.

## Testing criteria

Plain ExUnit (unit + property) against the existing fixtures, in the offsets suite. "Done"
means all of the following pass and the byte-for-byte round-trip invariant holds:

- **No-op (spec §8):** `faststart/1` and `fix_chunk_offsets/1` on fresh `trim` / `concat` /
  `extract_track` / `defragment` output: no raise; `stco`/`co64` tables **byte-identical** to
  the input; `serialize` round-trip preserved.
- **Relocation vs disk baseline (spec §8):** synthesize, then insert a `free` (or `udta`) box
  ahead of the `mdat` so it moves; assert `fix_chunk_offsets` shifts every offset by exactly the
  inserted box's size. **Correctness proof:** resolve each sample's bytes from the fixed tree
  (`samples/2` + `MdatSource`) and assert they equal the bytes from a disk `write/2` + `read/2`
  baseline of the same edited tree — in-memory fix matches the disk round-trip byte-for-byte.
- **`co64` promotion (spec §8):** relocation past a lowered `:co64_threshold` on a synthesized
  tree promotes `stco`→`co64` correctly (reuses the existing fixpoint).
- **Idempotence / composition (spec §8):** `fix(fix(x)) == fix(x)`; `trim |> faststart` fully in
  memory equals the same with a disk round-trip between stages.
- **Guard still raises (spec §7/§8):** a stamp-less hand-built `mdat`, and a size-changed `mdat`
  (`Layout.box_size(m) != source_size`), still raise `ArgumentError`.
- **Existing tests:** locate any test asserting `fix_chunk_offsets`/`faststart` **raises** on a
  synthesized mdat and flip it to assert the no-op (the capability is now supported).

## Dependencies

None. This is phase 1 and the only phase; it depends on no earlier phase. It builds only on
existing, already-shipped modules (`MdatSource`, `Layout`, `Offsets`, `ProgressiveBuild`,
`Trim`, `Extract`).
