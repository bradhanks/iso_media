# Virtual Seekable Media — Design

**Date:** 2026-06-09
**Status:** Approved (pending spec review)
**Source idea:** "Next feature — random-access reads over a transform tree."

## 1. Context & motivation

`iso_media` can already build a transform tree entirely in memory (`trim`, `concat`,
`fragment`, `defragment`, `faststart`, box surgery) and emit it two ways:

- `serialize/1` — materialize the whole tree to one binary (`FileSlice`s read into memory).
- `Serializer.stream/3` — write the tree to a raw `io_device` **sequentially**, streaming
  `FileSlice` payloads from disk so the full tree is never materialized.

What is missing is **random access**: given a transform tree, return an arbitrary byte range
`[offset, offset + length)` of its *would-be serialization* without materializing the whole
output, reading only the disk bytes the range actually touches.

This is the capstone of the recursive virtual I/O layer. It turns the library from a
parse/transform/write utility into a **streaming origin**: open a multi-GB file lazily, `trim`
or `faststart` or `fragment` it in memory, and serve byte `1_000_000..2_000_000` of the
*result* in `O(range)` memory with zero disk writes — exactly what an HTTP `Range` request, a
`Content-Range` response, or a seeking video player needs.

The guiding invariants are unchanged: **byte-for-byte round-trip** and **zero runtime
dependencies**.

## 2. Goals & non-goals

### Goals

- A pure functional **seek index** built once per tree, reused across many range reads.
- `read_range/3` — pread-style random access returning a `binary`.
- `stream_range/4` — a lazy, memory-safe `Stream` of chunks for large ranges, leak-safe under
  client disconnect.
- `content_length/1` — total output size (the `Content-Length` an HTTP layer needs), with no
  walk of payload bytes. (Named `content_length`, **not** `byte_size`, to avoid shadowing the
  `Kernel.byte_size/1` BIF — see §4.6.)

The **O(range) memory guarantee holds for `FileSlice`-backed (lazy-read) trees**; a tree
carrying a large *in-memory* binary leaf has those bytes already resident, so the streaming
origin's memory claim applies to `read(path, lazy: true)` inputs (the memory-safe path).
- A defining invariant that makes the whole feature property-testable against the already
  trusted `serialize/1`.

### Non-goals (scope boundary)

- **No bundled HTTP server.** Users wire `stream_range/4` into Plug/Bandit/Phoenix themselves;
  we ship a documented example only (preserves zero-dep).
- **No in-place index mutation.** Editing the tree invalidates the index — rebuild it. `build/1`
  is `O(boxes + leaves)` and cheap; an incremental/patchable index is out of scope.
- **No sequential-read cursor optimization in v1.** Players issue monotonically increasing
  ranges, so a last-segment hint would make sequential reads O(1) amortized. Recorded as future
  work; v1 is stateless O(log N) per read.

## 3. Public API

All on `ISOMedia`, delegating to `ISOMedia.SeekIndex`:

```elixir
@spec seek_index(tree) :: SeekIndex.t()
@spec read_range(SeekIndex.t(), offset :: non_neg_integer(), length :: non_neg_integer()) :: binary()
@spec stream_range(SeekIndex.t(), offset :: non_neg_integer(), length :: non_neg_integer(), chunk_size :: pos_integer()) :: Enumerable.t()
@spec content_length(SeekIndex.t()) :: non_neg_integer()
```

`tree` is a `%Box{}` or `[%Box{}]` (same shapes `serialize/1` accepts). The index is opaque —
callers never pattern-match its internals.

## 4. Internal design

### 4.1 `ISOMedia.SeekIndex` struct

```elixir
defstruct [:segments, :count, :byte_size]
```

- `segments` — an **opaque** flattened, offset-ordered physical map. **Default representation:
  a tuple** (`List.to_tuple/1` at build time) so `elem/2` gives O(1) random access and binary
  search is a true O(log N). The representation is deliberately private so we may later switch
  to pattern-matched list traversal for very small N (VM cache locality wins under a few
  hundred segments) without an API change.
- `count` — number of segments (tuple arity), so search bounds need no `tuple_size/1` per call.
- `byte_size` — total output size = `Σ Layout.box_size(box)` over the top-level boxes. Computed
  from sizes only; no payload bytes are read.

Each segment is a record describing one contiguous physical run of the output:

```elixir
%{abs_offset: non_neg_integer(), size: non_neg_integer(), provider: provider}

provider ::
    {:bytes, binary}        # computed header / full-box prefix / small inline leaf data
  | {:slice, FileSlice.t()} # disk-backed payload; NOT read at build time
```

`abs_offset` is the segment's start in the serialized output; segments are contiguous and
sorted, so `segments[i].abs_offset + segments[i].size == segments[i+1].abs_offset`, and the
last segment ends at `byte_size`.

### 4.2 `SeekIndex.build/1`

Walks the tree mirroring `Serializer.stream/3` / `to_iodata/1`, but **records** physical runs
instead of writing them. It threads a running absolute offset and accumulates segments:

- **Box header** (size + type, plus `largesize`/`uuid`/full-box version-flags where present) —
  recorded as `{:bytes, header_binary}` using the exact same header encoding the serializer
  emits, sized by `Layout.header_size/1`. Headers are small and held inline.
- **Container box** (`data: nil`, `children`) — emit its header segment, then recurse into
  children in order. No payload segment.
- **Leaf, in-memory binary** (`data` is a `binary`) — `{:bytes, data}`. (Large in-memory leaves
  are rare in practice; they live in the index as-is. `FileSlice` is the memory-safe path.)
- **Leaf, `FileSlice`** — `{:slice, fs}`. The bytes stay on disk.
- **Leaf, recursive segment list** (`[binary | FileSlice | [segment]]`, e.g. a synthesized
  `mdat`) — **flatten in place**: walk the parts in order, emitting `{:bytes, _}` /
  `{:slice, _}` segments, recursing through nested lists. Part sizes come from
  `Layout.segment_size/1`, so the index and `Layout.box_size/1` agree by construction.

The walk's emitted order is identical to `serialize/1`'s byte order, so concatenating every
segment's provider yields exactly `serialize(tree)`. Finally `List.to_tuple/1` freezes the
ordered segments into the O(1)-access representation.

> **Single source of offset truth.** Sizes come from `Layout.*` and header bytes from the same
> encoder the serializer uses — the index can never drift from `serialize/1`. This is the same
> discipline `MdatSource.collect/1` already follows.

### 4.3 `read_range/3` — clipping & splicing math

**Canonical clamp** (one definition, reused by `read_range/3` *and* the §5 oracle so they can
never drift). Given `offset, length >= 0` (API contract) and total `bs`:

```
clamp_range(offset, length, bs):
  start  = min(offset, bs)                 # past-EOF collapses to bs
  finish = min(offset + length, bs)        # exclusive; >= start since length >= 0
  return {start, finish}                   # read window is [start, finish)
```

`read_range/3`:

```
read_range(index, offset, length):
  # 1. Clamp to output bounds (HTTP-Range friendly: past-EOF returns the tail, not an error)
  {start, finish} = clamp_range(offset, length, content_length)
  if finish == start: return ""           # empty window: empty tree, zero-len, or offset >= EOF

  # --- PRECONDITION past this point: finish > start  =>  start < content_length
  #     =>  count >= 1 and a valid segment index exists. bsearch is never called on
  #     an empty tuple. (Empty tree has content_length == 0, so the guard above returns "".)

  # 2. Binary search the tuple for the segment containing `start`
  i = bsearch(segments, start)        # largest i with segments[i].abs_offset <= start
                                      #   (well-defined: start < content_length and
                                      #    segments[0].abs_offset == 0, so i in [0, count-1])

  # 3. Splice forward across segments until `finish`
  acc, pos = [], start
  while pos < finish:
    seg   = elem(segments, i)
    seg_lo = seg.abs_offset
    seg_hi = seg.abs_offset + seg.size
    take_lo = max(pos, seg_lo)
    take_hi = min(finish, seg_hi)
    rel = take_lo - seg_lo            # offset within this segment
    n   = take_hi - take_lo
    acc = [read_provider(seg.provider, rel, n) | acc]
    pos = take_hi
    i   = i + 1
  return IO.iodata_to_binary(reverse(acc))
```

The three structural cases fall out of the loop automatically:

- **start segment** — partial *tail* (`rel > 0`, `take_hi == seg_hi`).
- **interior segments** — read in full (`rel == 0`, `n == seg.size`).
- **end segment** — partial *prefix* (`rel == 0`, `take_hi == finish < seg_hi`).
- **single-segment read** — degenerate case where start and end land in the same segment
  (`rel >= 0`, `take_hi == finish`).

`read_provider/3`:

- `{:bytes, bin}` → `:binary.part(bin, rel, n)`.
- `{:slice, fs}` → **ephemeral, leak-proof** open/pread/close (mirrors `FileSlice.read/1`):
  `FileSlice.read_range(fs, rel, n)` (new — see §4.5). One bounded read; no long-lived fd.

`bsearch/2` operates on the tuple via `elem/2` (O(1) access → true O(log N)).

### 4.4 `stream_range/4` — lazy, leak-safe streaming

`stream_range(index, offset, length, chunk_size \\ 65_536)` returns an `Enumerable.t` that
yields `chunk_size`-byte binaries across the clamped range. Because a long range may span many
`FileSlice`s and survive a client disconnect, **file-descriptor lifecycle is managed with
`Stream.resource/3`**, whose `after_fun` is guaranteed to run on consumer halt, error, or
normal completion — so a dropped video connection closes any open fd deterministically.

Design: the stream is driven by the same clip-and-splice cursor as `read_range/3`, but yields
one chunk per step instead of accumulating. The `acc` threaded by `next_fun` **carries the
currently-open io_device** (the fd for the `FileSlice` being read, or `nil` between slices), so
`after_fun` can close whatever is open on halt/error/completion. For a run of bytes inside a
single `FileSlice`, the resource opens that file **once** and preads successive chunks (no
per-chunk open — avoids thousands of opens over a GB), and closes it both when the run ends
(slice boundary) and on consumer halt. `{:bytes, _}` providers yield directly from memory with
no fd.

This matches the existing codebase split: `FileSlice.read/1` (one-shot, ephemeral) underlies
`read_range/3`; `FileSlice.stream/3` (single callback-managed open) is the pattern
`stream_range/4` follows.

### 4.5 `FileSlice.read_range/3` (new)

A bounded partial read of a slice, leak-safe like `read/1`:

```elixir
@spec read_range(t(), rel :: non_neg_integer(), len :: non_neg_integer()) :: binary()
def read_range(%FileSlice{path: path, offset: offset, length: length}, rel, len)
    when rel >= 0 and len >= 0 and rel + len <= length do
  File.open!(path, [:read, :binary, :raw], fn io ->
    case :file.pread(io, offset + rel, len) do
      {:ok, data} when byte_size(data) == len -> data
      {:ok, data} -> raise "FileSlice.read_range: short read ..."
      :eof        -> raise "FileSlice.read_range: unexpected EOF ..."
      {:error, r} -> raise "FileSlice.read_range: #{:file.format_error(r)} ..."
    end
  end)
end
```

The `rel + len <= length` guard makes out-of-bounds a contract violation, not a silent short
read.

### 4.6 Naming: `content_length/1`, not `byte_size/1`

The public total-size accessor is `content_length/1`. Defining `def byte_size/1` on `ISOMedia`
or `SeekIndex` would shadow the auto-imported `Kernel.byte_size/1`: every *unqualified*
`byte_size(bin)` inside those modules would resolve to the local function instead of the BIF,
silently breaking binary-size calls (e.g. the `byte_size(data) == len` guard in §4.5, and any
size math in `read_range`). `content_length/1` avoids the shadow entirely and names the HTTP
concept it serves (§8). The `SeekIndex` struct keeps its internal `:byte_size` field (a struct
key, not a function, so no shadow); `content_length/1` simply returns it.

## 5. The defining invariant (test oracle)

A new round-trip law, parallel to `serialize(parse(file)) == file`. It is derived from the
**same `clamp_range/3` as §4.3** so the oracle and the implementation cannot diverge:

> For any tree `t`, with `idx = SeekIndex.build(t)` and `full = serialize(t)`,
> `bs = Kernel.byte_size(full)`, and `{start, finish} = clamp_range(offset, length, bs)`:
> for all `offset >= 0, length >= 0`:
>
> ```elixir
> read_range(idx, offset, length) == :binary.part(full, start, finish - start)
> ```
>
> and `content_length(idx) == bs`, and `read_range(idx, 0, content_length(idx)) == full`.

Because both sides take their window from the one `clamp_range/3` definition, there is a single
clamp to get right. `serialize/1` is the trusted oracle, so this is directly property-testable.
(Note the explicit `Kernel.byte_size/1` qualification — see §4.6.)

## 6. Edge cases

- Zero-length read → `""`.
- `offset >= byte_size` → `""` (clamped tail).
- `offset + length > byte_size` → returns available tail, no error (HTTP-Range semantics).
- Range exactly on a header/payload boundary.
- Range entirely inside one `FileSlice` — the hot path: one `pread`, zero waste.
- Range crossing a recursive segment-list `mdat` (synthesized by `trim`/`fragment`/`concat`).
- `largesize` (64-bit) and `uuid` extended-type headers — sizes already correct via
  `Layout.header_size/1`; header bytes emitted by the serializer's encoder.
- Empty tree / `byte_size == 0`.

## 7. Testing plan

Implement the property oracle (§5) **before** the slice-and-splice logic (TDD), so off-by-one
errors surface immediately.

- **Property test** — random `(offset, length)` (including out-of-range, zero-length, exact
  boundaries) over a fixture matrix: parsed files, lazy-read (`read(path, lazy: true)`) trees,
  and synthesized trees from `trim` / `fragment` / `concat` / `faststart`. Assert byte-equality
  with the `:binary.part` oracle and `byte_size` equality.
- **Memory-safety test** — `stream_range/4` over a large `FileSlice`-backed range reads only the
  touched bytes (assert via chunk count and that no full materialization occurs); confirm fd
  cleanup on early `Enum.take` / halt.
- **Composition test** — `read_range/3` over an in-memory `trim |> fragment` tree, proving it
  works on synthesized segment-list `mdat`s, not just parsed files.
- **Representation-equivalence test** — if/when a small-N list strategy is added, assert it
  returns identical bytes to the tuple strategy.

## 8. HTTP / Plug integration (documentation only)

A README/guide section (no code compiled into the lib) showing the killer app: parse `Range`,
build the index once (or per request), and stream the response — e.g. `Plug.Conn`
`send_chunked/2` fed by `stream_range/4`, with `Content-Length` from `content_length/1` and a
`206 Partial Content` `Content-Range`. Demonstrates a zero-dep streaming origin that can
`faststart`/`trim`/`fragment` on the fly. (The O(range) memory claim assumes `FileSlice`-backed
lazy trees — see §2.)

## 9. Performance notes

- `build/1`: O(boxes + leaves); reads no payload bytes; allocates a small tuple.
- `read_range/3`: O(log N) search + O(k) splice over the k touched segments; disk I/O bounded
  to exactly the requested bytes.
- `stream_range/4`: O(range / chunk_size) chunks; at most one open fd per touched `FileSlice` at
  a time.
- **Future:** a sequential-read cursor/hint (players issue increasing ranges) → O(1) amortized
  search on the sequential path. Out of scope for v1; the opaque representation leaves room.

## 10. Module touch list

- **New:** `lib/iso_media/seek_index.ex` (`build/1`, `read_range/3`, `stream_range/4`,
  `content_length/1`, private `clamp_range/3` + tuple bsearch + splice).
- **New fn:** `FileSlice.read_range/3`.
- **Expose (DRY):** `Serializer.encode_header/2` is currently **private** (`serializer.ex:69`).
  §4.2 reuses it to emit header bytes — so promote it to a public `Serializer.header_bytes/1`
  (computing `body_len` from `Layout.box_size - Layout.header_size` internally). Without this,
  `SeekIndex` would duplicate the 3-clause `:compact`/`:large`/`:eof` encoder, violating the
  single-source-of-truth discipline §4.2 claims.
- **Edit:** `lib/iso_media.ex` — delegations `seek_index/1`, `read_range/3`, `stream_range/4`,
  `content_length/1`.
- **Reuse (unchanged):** `Layout.header_size/box_size/segment_size`, the (now public) serializer
  header encoder, `MdatSource` segment-resolution discipline.
- **Tests:** `test/iso_media/seek_index_test.exs` (property + unit), fixtures reused from
  existing trim/fragment/concat tests.
- **Docs:** README HTTP-integration section; CLAUDE.md module-map entry; ROADMAP "Shipped".
