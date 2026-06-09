# Synthesized-`mdat` Chunk Offsets (no disk round-trip) — Design

**Date:** 2026-06-09
**Status:** Approved (pending spec review)
**Source idea:** ROADMAP — "`faststart/1` and `fix_chunk_offsets/1` raise on a synthesized
(chained) `mdat`." Make them work in memory instead.

## 1. Context & motivation

`ISOMedia.Offsets.fix_chunk_offsets/1` recomputes `stco`/`co64` chunk offsets after boxes
move, and `faststart/1` is built on top of it. Both **raise** on a *synthesized* `mdat` — one
produced in memory by `trim`/`concat`/`extract_track`/`defragment`, whose `data` is a segment
list and which carries no `source_offset`/`source_size`:

```elixir
# offsets.ex check_integrity!/1
is_nil(m.source_offset) or is_nil(m.source_size) ->
  raise ArgumentError, "fix_chunk_offsets: an mdat has no source position (synthesized?)..."
```

Today the only way to `faststart` (or otherwise re-fix offsets on) a synthesized tree is to
`write/2` it to disk and `read/2` it back, so the `mdat` becomes a parsed box with a real
`source_offset`. That disk round-trip defeats the library's in-memory pipeline guarantee.

**Key fact that makes this easy:** a synthesized `mdat`'s chunk offsets are *already correct*
for the builder's `[ftyp, moov, mdat]` layout. The builders compute the mdat's `payload_start`
(`progressive_build.ex:64`, `trim.ex:72`, `extract.ex:77`) and bake absolute offsets against
it. The offsets aren't wrong — `fix_chunk_offsets` simply has no **basis** to measure a delta
from, so it refuses rather than risk a wrong remap. And because a synthesized `mdat` is a single
contiguous payload block, when it *moves* (a box is inserted/removed/reordered) every chunk
offset shifts by one **uniform delta** — exactly what `fix_chunk_offsets` already does for parsed
mdats.

Invariants unchanged: **byte-for-byte round-trip**, **zero runtime dependencies**, and the
in-memory composition guarantee (chaining ops without a disk round-trip yields identical bytes).

## 2. Goals & non-goals

### Goals
- `fix_chunk_offsets/1` and `faststart/1` accept synthesized trees without raising.
- On an **unedited** synthesized tree they are a **no-op** (zero delta; offsets byte-identical),
  idempotent and composable.
- On a synthesized tree whose `mdat` has **moved** (box added/removed/reordered, e.g. inserting a
  `free`/`udta`, or `faststart` reordering `moov`/`mdat`), every chunk offset is remapped
  correctly — no disk round-trip.

### Non-goals (scope boundary)
- **Sample-level offset editing** — recomputing offsets from `stsc`/`stsz` to handle payload
  *reordering/resizing*. That is the ROADMAP's deferred item and remains deferred; we handle
  *relocation* of an unchanged contiguous payload only. A genuine size change still raises (the
  fixer cannot honestly remap it).
- **Fragmented (`moof`) offsets** — `trun` data offsets are moof-relative, not `stco`; out of
  scope (`fix_chunk_offsets` is a progressive-only operation).

## 3. Approach

Give synthesized mdats the same **basis** parsed mdats have, so the existing offset machinery
applies unchanged. A single shared constructor stamps `source_offset`/`source_size` at build
time; `offsets.ex` and `faststart` are **not modified**.

This was chosen over (B) inferring the basis from `min(chunk offsets)` inside `fix_chunk_offsets`
— which needs no synthesizer changes but couples correctness to an *implicit* "first chunk at
payload byte 0" packing invariant — and over (C) full sample-level recompute (the deferred,
heavier item). (A) makes the basis **explicit and robust** and reuses 100% of the existing
fix/faststart/`co64`-promotion/idempotence code.

## 4. Component: `MdatSource.synthesized_mdat/3`

`MdatSource` already owns synthesized-`mdat` segment resolution (`collect/1`, `segment/3`), so the
constructor lives there alongside its resolver.

```elixir
@doc """
Build a synthesized segment-list `mdat`, stamped with the basis position its chunk offsets were
written against. `payload_start` is the absolute byte offset of the mdat payload in the layout
the offsets were computed for (what the builder already used to bake them). The stamp lets
`Offsets.fix_chunk_offsets/1` remap the table if the mdat later moves.
"""
@spec synthesized_mdat([segment], Box.size_mode(), non_neg_integer()) :: Box.t()
def synthesized_mdat(segments, size_mode, payload_start) do
  box = %Box{type: "mdat", data: segments, size_mode: size_mode}
  %{box | source_offset: payload_start - Layout.header_size(box),
          source_size: Layout.box_size(box)}
end
```

- `source_offset` = mdat **box start** = `payload_start − header_size`.
- `source_size` = `Layout.box_size(box)` — the single source of truth, self-consistent with
  serialization (so `check_integrity!`'s `Layout.box_size(m) == source_size` holds by
  construction).
- The caller passes the `payload_start` it already computed; `Layout` derives the rest. No new
  size arithmetic is duplicated.

## 5. Integration — three one-line swaps

Each progressive synthesizer replaces its bare mdat literal with the constructor. Nothing else
in them changes (each already has `mdat_payload_start` in scope).

| Module | Site | Change |
|--------|------|--------|
| `ProgressiveBuild` | `:88` (Concat + Defragment) | `%Box{type: "mdat", data: segments, size_mode: mdat_mode}` → `MdatSource.synthesized_mdat(segments, mdat_mode, mdat_payload_start)` |
| `Trim` | `:92` | same swap |
| `Extract` | `:83` | same swap |

These three cover every progressive synthesis path (`concat` and `defragment` both route through
`ProgressiveBuild`). `Fragment` produces `moof`+`mdat` with moof-relative offsets — out of scope,
untouched.

## 6. Why `offsets.ex` / `faststart` need zero change

With the stamp present, trace the existing code:

- **`check_integrity!`** — `source_offset`/`source_size` present; `Layout.box_size(m) ==
  source_size` ✓. No raise.
- **`mdat_ranges`** — `old_payload_start = source_offset + Layout.header_size(m) = payload_start`
  (the exact basis the baked offsets assume). `delta = new_payload_start − payload_start`:
  - **Unedited** → `new_payload_start == payload_start` → **delta 0** → offsets returned
    byte-identical (the no-op / idempotent half).
  - **Moved** → `delta = shift` → every offset corrected uniformly (the relocation half).
- **`delta_for!`** — baked offsets lie within `[box_start, box_end)` ✓ (they point into the
  payload, a subrange of the box).
- **`faststart`** — `move_moov_first` is a no-op on `[ftyp, moov, mdat]`; the subsequent delta-0
  `fix_chunk_offsets` returns the tree. No raise. (If the user has manually placed `mdat` before
  `moov`, `move_moov_first` moves it and the non-zero delta corrects the table.)

The `stco→co64` promotion fixpoint and `rebase_mdats` idempotence machinery apply unchanged:
synthesized trees now flow through the identical path as parsed ones.

## 7. Error handling / guard semantics

The `check_integrity!` raises remain meaningful and are intentionally **not** weakened:
- A genuinely basis-less `mdat` (e.g. a hand-built `%Box{type: "mdat", data: <binary>}` with no
  stamp) still raises — we cannot remap what has no basis.
- A **size-changed** mdat (`Layout.box_size(m) != source_size`) still raises — that signals real
  sample-level editing the fixer cannot honestly handle.

We are not loosening the guard; we are giving the synthesizers a legitimate basis so they pass it
truthfully. Semantic note: for a synthesized box `source_offset` denotes the **basis position**
(where the current offsets were written against), not "position in an original file" — consistent
with the `offsets.ex` moduledoc, which already defines it as "current basis position."

## 8. Testing

- **No-op** — `faststart/1` and `fix_chunk_offsets/1` on fresh `trim` / `concat` /
  `extract_track` / `defragment` output: no raise; `stco`/`co64` tables byte-identical to the
  input; `serialize` round-trip preserved.
- **Relocation** — synthesize, then insert a `free` (or `udta`) box ahead of the `mdat` so it
  moves; `fix_chunk_offsets` shifts every offset by exactly the inserted box's size. **Proof of
  correctness:** resolve each sample's bytes from the fixed tree (via `samples/2` + `MdatSource`)
  and assert they equal the bytes obtained by a disk `write/2` + `read/2` baseline of the same
  edited tree — i.e. the in-memory fix matches the disk round-trip byte-for-byte.
- **`co64` promotion** — relocation past a lowered `:co64_threshold` on a synthesized tree
  promotes `stco`→`co64` correctly (reuses the existing fixpoint).
- **Idempotence / composition** — `fix(fix(x)) == fix(x)`; `trim |> faststart` fully in memory
  equals the same with a disk round-trip between stages.
- **Guard intact** — a stamp-less hand-built `mdat`, and a size-changed `mdat`, still raise.
- **Existing tests** — locate any test asserting `fix_chunk_offsets`/`faststart` *raises* on a
  synthesized mdat and flip it to assert the no-op (the capability is now supported).

## 9. Module touch list

- **New:** `MdatSource.synthesized_mdat/3`.
- **Edit:** `ProgressiveBuild` (`:88`), `Trim` (`:92`), `Extract` (`:83`) — one-line mdat swap each.
- **Unchanged (by design):** `Offsets` (`fix_chunk_offsets`/`faststart`) — the whole point.
- **Tests:** new no-op/relocation/promotion/composition cases in the offsets suite; update any
  "raises on synthesized" assertion.
- **Docs:** ROADMAP (move "synthesized-mdat offset" item from deferred to shipped); CLAUDE.md
  `MdatSource` and `Offsets` module-map notes.
