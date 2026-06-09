# Phase 1 — Virtual Seekable Media (random-access reads over a transform tree)

## Phase metadata

- **Phase number:** 1 (single atomic phase)
- **Short title:** Virtual seekable media — `SeekIndex` + `read_range`/`stream_range`/`content_length`
- **Source spec:** `docs/superpowers/specs/2026-06-09-virtual-seekable-media-design.md`
- **Feature name:** `virtual-seekable-media`

## Decomposition rationale (why atomic)

The null hypothesis — deliver as ONE phase — holds here, and the spec gives no
reason to reject it.

`iso_media` is a pure, zero-runtime-dependency, in-memory binary-parsing library.
This feature adds a random-access read path over an already-existing transform
tree. Concretely there is:

- **No deployment-ordering risk.** Nothing ships to a server, no consumers are
  cut over, no feature flag gates a rollout. The whole thing is library code
  verified by `mix test`.
- **No data-safety / migration risk.** Migrations are "none" (§ below). There is
  no persistent state, no backfill, no schema.
- **No external-consumer dependency.** The HTTP/Plug integration is
  *documentation only* (spec §8 — "No bundled HTTP server", a non-goal in §2),
  so there is no second system that must be shipped-and-verified before this one
  is usable.

The deliverables *do* have an internal build/compile order
(`FileSlice.read_range/3` and the now-public `Serializer.header_bytes/1` are
prerequisites of `SeekIndex.build/1` and `read_range/3`; `stream_range/4` reuses
`read_range/3`'s verified clip-and-splice cursor). But that ordering is a
*within-phase TDD ordering*, not a cross-phase deploy/verification boundary —
the spec's own §7 mandates writing the property oracle (§5) **before** the
slice-and-splice logic, i.e. the verification discipline lives inside one phase.

Splitting would actively hurt: the entire feature is proved by a **single**
property oracle (§5) against the already-trusted `serialize/1`. That oracle
exercises `build/1`, `content_length/1`, `read_range/3`, and (for memory-safety)
`stream_range/4` together — there is no meaningful "half" of this feature that is
independently shippable-and-verifiable. `read_range/3` without `stream_range/4`
is an incomplete public API (§3 lists all four together); `stream_range/4`
literally shares `read_range/3`'s cursor, so they are co-verified, not
sequentially de-risked. More phases here would add ceremony with zero
risk reduction. **One atomic phase.**

## Scope boundary

**In scope (everything in the design spec §1–§10):**

- New module `ISOMedia.SeekIndex` (`lib/iso_media/seek_index.ex`):
  - the `%SeekIndex{segments, count, byte_size}` struct (§4.1; `segments` an
    opaque offset-ordered tuple of `%{abs_offset, size, provider}` records,
    `provider :: {:bytes, binary} | {:slice, FileSlice.t()}`),
  - `build/1` (§4.2) — walks the tree mirroring `Serializer.stream/3`/`to_iodata/1`,
    recording physical runs instead of writing; header+uuid segment, container
    recursion, in-memory binary leaf, `FileSlice` leaf, and **flattening** of the
    recursive `[binary | FileSlice | [segment]]` segment-list leaf; freezes to a
    tuple via `List.to_tuple/1`,
  - `read_range/3` (§4.3) — canonical `clamp_range/3`, tuple `bsearch/2`, the
    forward clip-and-splice loop, and `read_provider/3`
    (`{:bytes,_}` → `:binary.part`, `{:slice,_}` → `FileSlice.read_range/3`),
  - `stream_range/4` (§4.4, default `chunk_size \\ 65_536`) — lazy `Stream.resource/3`
    driven by the same cursor, threading the currently-open io_device in `acc` so
    `after_fun` closes any open fd on halt/error/completion; one open per touched
    `FileSlice`,
  - `content_length/1` (§4.6) — returns the struct's `:byte_size` field; named
    `content_length` (NOT `byte_size`) to avoid shadowing `Kernel.byte_size/1`,
  - the public-boundary **input guards** on `read_range/3` and `stream_range/4`
    (§3): a valid-input clause (`is_integer and >= 0` for both `offset` and
    `length`) paired with an explicit fallback that raises `ArgumentError` with a
    clear message — never a `FunctionClauseError`, never a negative `start` into
    the splice math.
- New fn `ISOMedia.FileSlice.read_range/3` (§4.5) — bounded, leak-safe partial
  pread (ephemeral `File.open!` + `:file.pread`), with the
  `rel + len <= length` contract guard and loud raise on short-read/EOF/error.
- Promote `Serializer.encode_header/2` (currently private, `serializer.ex:69`)
  to a public **`Serializer.header_bytes/1`** (§4.2, §10) returning the full
  pre-payload bytes `encode_header(box, body_len) <> (box.uuid || <<>>)`, with
  `body_len` computed exactly as `stream_box` does (`serializer.ex:103`); its
  byte size equals `Layout.header_size/1` by construction (uuid included). This
  is the single-source-of-truth header encoder reused by `SeekIndex.build/1`.
- `ISOMedia` delegations (`lib/iso_media.ex`, §10): `seek_index/1`,
  `read_range/3`, `stream_range/4`, `content_length/1`.
- Docs: README HTTP/Plug-integration section (§8, documentation only — no
  compiled code), CLAUDE.md module-map entry for `SeekIndex`, ROADMAP "Shipped".

**Deferred / explicitly out of scope (per §2 non-goals & §9):**

- No bundled HTTP server / Plug / Bandit / Phoenix dependency — example is
  documentation only (preserves zero-dep).
- No in-place / incremental / patchable index mutation — editing the tree means
  rebuild via `build/1`.
- No sequential-read cursor / last-segment hint optimization in v1 — the opaque
  representation leaves room for it later, but v1 is stateless O(log N) per read.
- No switch to a small-N pattern-matched list strategy now — the representation
  is private so it can change later without an API break (a
  representation-equivalence test, §7, guards that future swap).

## Migrations

**None.** This is a pure in-memory binary-parsing library with no database, no
schema, no persistent state, and no backfill.

## Domain & API

Public API (all on `ISOMedia`, delegating to `ISOMedia.SeekIndex`; spec §3):

```elixir
@spec seek_index(tree) :: SeekIndex.t()
@spec read_range(SeekIndex.t(), offset :: non_neg_integer(), length :: non_neg_integer()) :: binary()
@spec stream_range(SeekIndex.t(), offset :: non_neg_integer(), length :: non_neg_integer(), chunk_size :: pos_integer()) :: Enumerable.t()
@spec content_length(SeekIndex.t()) :: non_neg_integer()
```

`tree` is a `%Box{}` or `[%Box{}]` (same shapes `serialize/1` accepts). The index
is opaque — callers never pattern-match its internals.

Module / function boundaries delivered:

- **`ISOMedia.SeekIndex` (new, §4.1–§4.4, §4.6)** — `build/1`, `read_range/3`,
  `stream_range/4`, `content_length/1`, plus the private `clamp_range/3`
  (canonical clamp, also used by the §5 oracle so they cannot drift), tuple
  `bsearch/2`, the splice loop, and `read_provider/3`.
- **`ISOMedia.FileSlice.read_range/3` (new, §4.5)** — bounded leak-safe partial
  read; the disk-read primitive under `read_provider`'s `{:slice,_}` path.
- **`ISOMedia.Serializer.header_bytes/1` (newly public, §4.2 / §10)** — full
  pre-payload header bytes (size+type+largesize, then the 16 uuid bytes for an
  extended-type box); the single header encoder shared with `build/1`. Critical
  correctness point (§4.2, §6): the 16 uuid bytes are emitted *after*
  `encode_header`, so the header provider must concatenate them or a `uuid` box's
  index runs 16 bytes short and the byte-exact invariant breaks.
- **Reuse (unchanged):** `Layout.header_size/1`, `Layout.box_size/1`,
  `Layout.segment_size/1` (so the index and `Layout` agree on sizes by
  construction — the same single-source-of-truth discipline `MdatSource.collect/1`
  follows); `MdatSource` segment-resolution discipline as the design precedent.
- **`ISOMedia` delegations (§10):** `seek_index/1`, `read_range/3`,
  `stream_range/4`, `content_length/1`.

DRY watch-item (spec §10, standard 7): `SeekIndex.build`'s flattening of the
recursive `[binary | FileSlice | [..]]` shape and `MdatSource`'s resolution walk
the same structure for different purposes (build a full flat map vs. resolve one
range) — they are NOT duplication today, but if a third walker appears, factor a
shared `Layout`-level segment-walk helper rather than a third parallel recursion.

## UI & components

**None.** This library has no UI, no LiveView, no components. The only
user-facing surface is the documented HTTP/Plug *example* in the README (§8),
which is prose + a code sample, not compiled library code.

## Testing criteria

Plain ExUnit (unit + property). Per spec §7, **implement the property oracle (§5)
BEFORE the slice-and-splice logic (TDD)** so off-by-one errors surface
immediately. Tests live in `test/iso_media/seek_index_test.exs`, reusing fixtures
from the existing trim/fragment/concat tests.

The defining invariant / oracle (§5), derived from the **same `clamp_range/3`** as
the implementation so oracle and code cannot diverge — for any tree `t`, with
`idx = SeekIndex.build(t)`, `full = serialize(t)`,
`bs = Kernel.byte_size(full)` (note the explicit `Kernel.` qualification, §4.6),
and `{start, finish} = clamp_range(offset, length, bs)`, for all
`offset >= 0, length >= 0`:

```elixir
read_range(idx, offset, length) == :binary.part(full, start, finish - start)
```

and `content_length(idx) == bs`, and
`read_range(idx, 0, content_length(idx)) == full` (the full byte-exact
round-trip, parallel to `serialize(parse(file)) == file`).

Concrete tests and "done" means all green:

1. **Property test (§7, §5 oracle)** — random `(offset, length)` (including
   out-of-range, zero-length, exact header/payload boundaries) over a fixture
   matrix: parsed files, lazy-read (`read(path, lazy: true)`) trees, synthesized
   trees from `trim` / `fragment` / `concat` / `faststart`, **and at least one
   tree containing a `uuid` extended-type box** (mandatory — exercises the
   header+uuid provider §4.2; without it the uuid path is untested and the
   16-byte bug, §6, goes uncaught). Assert byte-equality with the `:binary.part`
   oracle and `content_length` equality.
2. **Memory-safety test (§7)** — `stream_range/4` over a large
   `FileSlice`-backed range reads only the touched bytes (assert via chunk count
   and that no full materialization occurs); confirm fd cleanup on early
   `Enum.take` / consumer halt (the `Stream.resource/3` `after_fun` runs on halt).
3. **Input-validation test (§7, §6)** — negative / float / non-integer
   `offset`/`length` raise `ArgumentError` at the public boundary (never reach
   `clamp_range`/`bsearch`/the splice math); past-EOF (`offset >= content_length`)
   and zero-length return `""`; `offset + length > content_length` returns the
   available tail with no error (HTTP-Range semantics).
4. **Composition test (§7)** — `read_range/3` over an in-memory
   `trim |> fragment` tree, proving it works on synthesized segment-list `mdat`s,
   not just parsed files (no disk round-trip between stages).
5. **Edge cases (§6)** — zero-length read; range exactly on a header/payload
   boundary; range entirely inside one `FileSlice` (the hot path: one `pread`);
   range crossing a recursive segment-list `mdat`; `largesize` (64-bit) headers;
   empty tree / `content_length == 0`.
6. **Representation-equivalence test (§7)** — *if/when* a small-N list strategy is
   added, assert it returns identical bytes to the tuple strategy. (Placeholder /
   guard for the deferred optimization; the tuple strategy is the only one in v1.)

Test hygiene: any test writing scratch files uses ExUnit's `@tag :tmp_dir`
(standard 5) so the suite stays isolated and `async`-safe.

**Done** = property oracle holds across the full fixture matrix (incl. the uuid
fixture), all unit/edge/input-validation/composition/memory-safety tests pass,
`mix format` clean, and the byte-exact invariant
`read_range(idx, 0, content_length(idx)) == serialize(tree)` is proved.

## Dependencies

None on other phases — this is the single, self-contained phase for the feature.
It depends only on already-shipped library internals it reuses: `serialize/1`,
`Serializer.stream/3`/`to_iodata/1`, `Layout.header_size`/`box_size`/`segment_size`,
`FileSlice` (`read/1`/`stream/3`), the recursive segment-list `mdat` shape, and
the `read(path, lazy: true)` lazy-parse path — all present in the current tree.
