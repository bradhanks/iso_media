# Design: `iso_media` — lossless ISOBMFF box surgery

**Date:** 2026-05-31
**Status:** Approved (design phase)

## Goal

A pure-Elixir library to deconstruct any ISO Base Media File Format (ISOBMFF,
ISO/IEC 14496-12) file — MP4, MOV, M4A, HEIF, etc. — into its constituent boxes,
expose every part for inspection and editing, and re-serialize back into a valid
file. The core guarantee is a **byte-perfect lossless round-trip**; non-destructive
tree edits are layered on top. This foundation is intended to grow toward
higher-level operations (e.g. video editing) later.

## Decisions (from brainstorming)

- **Direction A — generic lossless box surgery**, not per-type semantic schemas.
  Every box is preserved byte-for-byte, including unknown/vendor boxes.
- **Hybrid recursion** — a known-container registry decides container vs leaf by
  default; an opt-in heuristic sniffs unknown vendor boxes for nested children.
- **Offset handling: phased.** Phase 1 is pure lossless surgery — the library does
  NOT auto-rewrite absolute-offset tables (`stco`/`co64`). The caller owns
  correctness when moving data those tables point into. Smart re-serialization
  (auto offset fixup) is an explicit later phase.
- **Memory model: whole file in memory as a binary.** Elixir sub-binaries share
  the original memory (zero-copy slices), and serialization uses iolists, so even
  multi-GB `mdat` payloads are cheap references. File-backed lazy payloads are a
  possible later phase.
- **Module namespace: `ISOMedia`** (replacing the inconsistent `IsoMedia`/`ISOMedia`
  mix). OTP app stays `:iso_media`.

## Core data structure

Every box — known or not — is one generic struct:

```elixir
%ISOMedia.Box{
  type: "moov",            # 4-char type tag (string)
  data: nil,               # leaf payload (zero-copy sub-binary); nil ⇒ container
  children: [%Box{}],      # child boxes; [] for leaves
  uuid: nil,               # 16-byte extended type, set only when type == "uuid"
  size_mode: :compact      # :compact (32-bit) | :large (64-bit) | :eof
}
```

- `data == nil` ⇒ container; `data` is a binary ⇒ leaf. A container always carries a
  `children` list (possibly empty).
- `size_mode` records how the original encoded the box size so re-serialization
  reproduces exact bytes:
  - `:compact` — 32-bit size field.
  - `:large` — size field == 1, real size in the following 64-bit `largesize`.
  - `:eof` — size field == 0, box runs to end of file (last top-level box only).
  - On edit, size is recomputed; `size_mode` chooses the encoding.

## Components

### `ISOMedia` (public API)
- `parse(binary, opts \\ [])` → `{:ok, [%Box{}]}` | `{:error, reason}`. A file is a
  sequence of top-level boxes (`ftyp`, `moov`, `mdat`, …), returned as a list.
- `serialize(boxes)` → `binary`. Accepts a box or a list of boxes.
- Convenience: read a file path and parse; serialize and write a path.

### `ISOMedia.Parser` (binary → tree)
Header decode is pure pattern matching:

```elixir
<<size::32, type::binary-size(4), rest::binary>> = bin
```

Branches:
- `size == 1` → read 64-bit largesize from the next 8 bytes (`size_mode: :large`).
- `size == 0` → box runs to EOF (`size_mode: :eof`).
- `type == "uuid"` → next 16 bytes are the extended type → `uuid` field.
- Container types (per registry, or heuristic) → recurse into payload.
- Otherwise → leaf, `data` is a sub-binary slice of the payload.

`opts`:
- `:heuristic` (default `false`) — attempt nested-box detection on unknown types.

### `ISOMedia.Serializer` (tree → bytes)
Builds an iolist (no copying) → binary. Reconstructs each header from `type` + the
computed payload size, honoring `size_mode`, prepending `uuid` when present, then
concatenating children (recursively) or `data`.

Governing invariant: `parse(bin) |> elem(1) |> serialize() == bin` for well-formed
input.

### `ISOMedia.Registry` (container classification)
- A set of known container box types: `moov trak mdia minf stbl dinf edts udta
  mvex moof traf` (extensible).
- Heuristic detector: peek payload — do successive child sizes parse with printable
  4-char tags and sum exactly to the parent payload length? If so, treat as
  container.

### `ISOMedia.Box` (navigation & editing — the "however I want" surface)
Pure functions over the immutable tree, addressing boxes by type-path:

```elixir
Box.find(boxes, ~w(moov trak mdia))      # first match → %Box{} | nil
Box.find_all(boxes, ~w(moov trak))       # all matches → [%Box{}]
Box.update(boxes, path, fun)             # apply fun.(box) to ALL boxes matching path
Box.remove(boxes, path)                  # cut out ALL boxes matching path
Box.insert(boxes, path, box, at)         # splice box into the container at `path`
                                         #   (:start | :end | integer index)
Box.replace_data(box, binary)            # swap a leaf payload
```

Path-match semantics: `find` returns the first match; `find_all`, `update`, and
`remove` act on every box matching the type-path. `insert` targets the single
container found at `path`. All operations return a new tree (immutable).

### `ISOMedia.FullBox` (helper)
Many boxes begin with a `version` (1 byte) + `flags` (3 bytes) prefix. A shared
helper to read/write this prefix, used by typed views.

### `ISOMedia.Boxes.*` (typed views — layered, opt-in, incremental)
A behaviour:

```elixir
@callback decode(%ISOMedia.Box{}) :: struct
@callback encode(struct) :: %ISOMedia.Box{}
```

Each known box gets a plain-struct decode/encode pair (no Ecto). The raw tree never
depends on these — they are a convenience layer. First batch:

- `ftyp` → `ISOMedia.Boxes.FileType` (`major_brand`, `minor_version`,
  `compatible_brands`)
- `mvhd` → `ISOMedia.Boxes.MovieHeader`
- `tkhd` → `ISOMedia.Boxes.TrackHeader`
- `mdhd` → `ISOMedia.Boxes.MediaHeader`
- `hdlr` → `ISOMedia.Boxes.Handler`

## Project layout

```
lib/iso_media.ex              # public API: parse/1,2 · serialize/1
lib/iso_media/box.ex          # %Box{} struct + navigation/editing
lib/iso_media/parser.ex       # binary → boxes
lib/iso_media/serializer.ex   # boxes → iolist/binary
lib/iso_media/registry.ex     # container set + heuristic
lib/iso_media/full_box.ex     # version/flags helper
lib/iso_media/boxes/*.ex      # typed views (ftyp, mvhd, tkhd, mdhd, hdlr)
test/fixtures/*               # small real sample files (mp4/m4a/heic)
```

## Cleanup of existing code

- Delete `lib/iso_media/movie_box.ex`, `lib/iso_media/file_type_box.ex`, and the
  empty `lib/core/iso_ftyp.ex`. Their intent survives as typed views.
- Remove the `:fs` dependency (unused filesystem watcher). Core has no runtime deps.
- Add `:stream_data` as a test-only dependency for property-based round-trip tests.
- Rename all modules/tests to the `ISOMedia` namespace.

## Testing strategy

- **Round-trip property** (`StreamData`): generate random valid box trees →
  serialize → parse → assert identical. Plus `parse(file) |> serialize() == file`
  on real fixtures.
- **Header edge cases:** 64-bit largesize, `size == 0` to-EOF, `uuid` boxes, deep
  nesting, heuristic detection on a synthetic vendor container.
- **Navigation/editing:** find/find_all/update/remove/insert/replace_data, asserting
  immutability and correct re-serialization.
- **Typed views:** decode/encode round-trip per box against fixture-extracted boxes.
- **Fixtures:** generate tiny valid sample files (e.g. via `ffmpeg`) — a minimal
  MP4, M4A, and HEIF — small enough to commit.

## Out of scope (this phase)

- Automatic offset-table (`stco`/`co64`) rewriting on edit.
- File-backed/lazy payload reading.
- Full typed-view coverage of all box types (only the first batch above).
- Any media decoding/encoding (codec-level work).
