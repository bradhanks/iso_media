# Design: lazy file-backed payloads (large-file support)

**Date:** 2026-05-31
**Status:** Approved (design phase)
**Builds on:** Phase 1 (lossless box surgery) and Phase 2 (chunk-offset rewriting + faststart).

## Goal

Let `iso_media` parse, faststart, and write ISOBMFF files **larger than available
RAM**. Today `ISOMedia.read/2` loads the whole file into one binary (parsed boxes
are zero-copy slices of it, but the entire file stays resident). The fix: a leaf
box's payload may be a *reference to a region on disk* (`%FileSlice{}`) that is
never loaded into memory — only streamed disk→disk when writing. Phase 2's
`faststart`/`fix_chunk_offsets` already operate purely on sizes/offsets and never
read `mdat` bytes, so the metadata path is ready for this.

## Decisions (from brainstorming)

- **Scope:** size-threshold. In lazy mode, a leaf payload of length ≥
  `:lazy_threshold` (default 1 MB) becomes a `%FileSlice{}`; smaller payloads stay
  in-memory binaries. So bulk media (`mdat`) is lazy while editable metadata stays
  in memory — typed views and editing keep working with no "materialize first" step.
- **Reference:** inert `%ISOMedia.FileSlice{path, offset, length}` value; the file
  is reopened on demand to read. No long-lived handle to manage or leak.
- **Opt-in:** `ISOMedia.read(path, lazy: true)`. Default (`lazy: false`) is the
  exact current behavior — zero regression for Phase 1/2.
- **Write vs serialize:** `write/2` streams slices disk→disk (memory-safe, the
  large-file path); `serialize/1` materializes slices into memory and returns a
  binary (convenient for small trees; yields a test invariant).

## Components

### `ISOMedia.FileSlice` (new — `lib/iso_media/file_slice.ex`)
An inert value plus read helpers.

- `defstruct [:path, :offset, :length]` (`@type t :: %FileSlice{path: Path.t(),
  offset: non_neg_integer(), length: non_neg_integer()}`).
- `read(%FileSlice{})` → `binary` — opens the file, `:file.pread`s the range,
  closes; raises with the path+range on I/O error.
- `stream(%FileSlice{}, io_device, chunk_size \\ 65_536)` — preads the range in
  chunks and writes each to `io_device`; the source is opened once and read
  sequentially. Used by the streaming writer.

**Open mode & leak safety (applies to all file access here):**
- Open source files with `[:read, :binary, :raw]` and the output with
  `[:write, :binary, :raw]`. `:raw` bypasses the Erlang IO-server (less CPU/copying
  — meaningful for multi-GB streaming), but a `:raw` fd **must** be used with the
  `:file` module (`:file.pread/3`, `:file.write/2`), **not** `IO.binread`/
  `IO.binwrite` (those require an IO-server-backed device).
- Use the **callback form** `File.open(path, modes, fn io -> ... end)`, which closes
  the handle even if the body raises. This guarantees no descriptor leak if, e.g.,
  the output disk fills mid-stream and a `:file.write` fails. (Equivalent to a
  `try/after` close, but built in.)

A **leaf box's `data` is now `binary | %FileSlice{} | nil`** (`nil` ⇒ container,
unchanged). `Box.container?/leaf?` already classify correctly: a `FileSlice` leaf
has `data != nil`.

### `ISOMedia.Parser` — gains an `:offset` option
To support absolute offsets when the lazy parser parses a container body that does
not start at file offset 0:

- `parse(binary, opts)` accepts `:offset` (default `0`) — the absolute byte offset
  the binary begins at. It is threaded into the existing offset accounting so every
  box's `source_offset` is **absolute from the start of the original file**, not
  relative to the slice handed in.
- Existing callers (`opts` without `:offset`) are unaffected (default 0).

### `ISOMedia.LazyParser` (new — `lib/iso_media/lazy_parser.ex`)
`parse_file(path, opts)` → `{:ok, [%Box{}]} | {:error, reason}`. Walks the
**top-level** boxes by seeking, never holding the whole file:

1. Open the file; determine its total size (for `:eof` boxes).
2. At each top-level position, `pread` the header (8 bytes; +8 for largesize when
   size==1; +16 for `uuid`); compute `size_mode`, `payload_offset`,
   `payload_length`, and total `box_size`.
3. Dispatch:
   - **container type** (per `Registry`, or heuristic on a *read* box) → `pread` the
     box's full body into memory and parse it with
     `Parser.parse(body, offset: payload_offset, heuristic: ...)` so nested
     `source_offset`s are absolute. (Containers like `moov` are bounded in size.)
   - **leaf, `payload_length >= threshold`** → `%FileSlice{path, payload_offset,
     payload_length}`; do not read; seek past.
   - **leaf, `payload_length < threshold`** → `pread` the payload into memory.
4. Stamp `source_offset`/`source_size` on every box exactly as the eager parser
   does (top level here; nested via the `:offset`-threaded `Parser`).
5. `:eof` `mdat` (size field 0): `length = file_size − payload_offset`.

Notes:
- **Heuristic + lazy:** the `:heuristic` container sniff only applies to boxes whose
  payload is read (sub-threshold). A ≥-threshold unknown box stays an opaque
  `FileSlice` — the safest handling for a large unknown box.
- The file is opened only for the duration of `parse_file`; the returned tree holds
  only `FileSlice` *paths*, no open handle.

### `ISOMedia.Layout` — `FileSlice`-aware sizing
Add a new `box_size/1` clause **before** the binary-data clause:

- `box_size(%Box{data: %FileSlice{length: len}} = box) -> header_size(box) + len`

(`byte_size/1` on a `%FileSlice{}` struct would raise, so this must be an explicit
match, not a fallthrough.) `header_size/1` is unchanged (depends on `size_mode`/
`uuid`, not on `data`). With this one change, `faststart`/`fix_chunk_offsets` work
on a lazy tree unmodified, and the integrity check `box_size == source_size` holds
for slices.

### `ISOMedia.Serializer` — materialize + stream
- `materialize(boxes)` — walk the tree, replacing each `%FileSlice{}` leaf payload
  with `FileSlice.read/1`'s bytes; returns an all-in-memory tree.
- `serialize(boxes)` — `boxes |> materialize() |> to_iodata() |> IO.iodata_to_binary()`.
- `to_iodata/1` — add an `encode_payload(%Box{data: %FileSlice{}})` clause that
  **raises** a clear `ArgumentError` ("box payload is an unread FileSlice; use
  ISOMedia.write/2 to stream it, or serialize/1 to materialize"). `serialize/1`
  materializes first, so only direct `to_iodata` callers can hit this.
- `stream(boxes, io_device, chunk_size \\ 65_536)` — walk the tree writing to
  `io_device`: for each box write its header using the **same `size_mode`-aware
  header encoding** as `to_iodata` (so `:compact`/`:large` emit the computed size and
  `:eof` still emits size field `0`), where the body length is
  `Layout.box_size(box) − Layout.header_size(box)` (no payload read needed), then its
  body — in-memory `data` written directly, children streamed recursively, and a
  `FileSlice` streamed via `FileSlice.stream/3`. Peak memory ≈ `chunk_size` + the
  in-memory (metadata) boxes.

### `ISOMedia` (public API)
- `read(path, opts \\ [])` — when `opts[:lazy]` is true, dispatch to
  `LazyParser.parse_file(path, opts)` (honoring `:lazy_threshold`, default
  `1_048_576`, and `:heuristic`); otherwise the current eager path. Returns
  `{:ok, boxes} | {:error, reason}`.
- `write(path, boxes)` — open `path` with `File.open(path, [:write, :binary, :raw],
  fn io -> Serializer.stream(boxes, io) end)` (callback form auto-closes even on a
  mid-stream write failure). **Memory-safe for lazy trees.** Identical bytes to
  before for fully in-memory trees (no `FileSlice`s → the stream walk emits the same
  bytes `to_iodata` did). Runs the overwrite guard (below) before opening.
- `serialize/1` — unchanged signature; now materializes lazy trees (see above).

### `ISOMedia.Box` — `read_data/1`
- `read_data(%Box{data: %FileSlice{}} = box)` → `FileSlice.read(box.data)`
- `read_data(%Box{data: data}) when is_binary(data)` → `data`
- `read_data(%Box{data: nil})` → `nil` (container)

For materializing a single lazy leaf's bytes on demand (e.g. to run a typed view on
a leaf that ended up lazy under a small threshold). `replace_data/2` is unchanged
(swaps in an in-memory binary, dropping any slice).

## Error handling & preconditions

- **Overwrite guard (`write/2`):** raise `ArgumentError` if the output target is one
  of the tree's `FileSlice` sources — you cannot stream-overwrite the file you are
  reading from. Checked two ways: (a) `Path.expand/1` equality of output vs each
  source path; (b) when the output already exists, `File.stat/1` device+inode
  (`{major_device, minor_device, inode}`) equality (catches symlinks/hardlinks). A
  not-yet-existing output cannot share an inode with an existing source, so the two
  checks together cover it.
- **Stale/missing source:** a lazy tree depends on its source file staying put and
  unchanged until written. `FileSlice.read/stream` surface `File.open`/`pread`
  failures as a raised error including the path and byte range. Documented as a
  precondition.
- **Typed views need in-memory data:** with the default threshold, all metadata
  stays in memory and typed views (`FileType.decode/1`, etc.) work unchanged. Under
  a tiny threshold a metadata box could become a `FileSlice`; call `Box.read_data/1`
  first in that case. Typed-view `decode/1` functions stay pure (no implicit I/O).
- **`serialize/1` on a lazy tree** may use a lot of memory (it reads every slice);
  `write/2` is the large-file path. Documented.

## Memory model (the win)

Faststarting a multi-GB file:
`read(path, lazy: true)` (only headers + metadata boxes in RAM; `mdat` is a
`FileSlice`) → `faststart/1` (pure metadata rearrange + offset fix) →
`write(out, …)` (`mdat` streamed disk→disk in 64 KB chunks). Peak memory ≈ the
metadata (`moov`) + one chunk, independent of file size.

## Testing

- **Unit:** `FileSlice.read`/`stream`; `LazyParser` yields a `FileSlice` for a
  ≥-threshold leaf and an in-memory binary for a sub-threshold one; `source_offset`/
  `source_size` (including nested boxes) equal the eager parser's; `:eof` `mdat`
  length resolves; `Layout.box_size` on a `FileSlice` leaf equals the eager size;
  `Parser.parse(bin, offset: n)` stamps absolute offsets.
- **Lazy ≡ eager invariant (real fixtures, low threshold so `mdat` is a slice):**
  `serialize(read(f, lazy: true)) == serialize(read(f)) == File.read!(f)`.
- **Streaming write:** `write(out, read(f, lazy: true))` then
  `File.read!(out) == File.read!(f)`.
- **Headline — lazy faststart without materializing `mdat`:**
  `read(f, lazy: true) |> faststart() |> ISOMedia.write(out)`; re-parse `out`,
  assert `moov` precedes `mdat` and every chunk resolves to its bytes.
- **Overwrite guard** raises (including a symlink-to-source case).
- **`to_iodata` on an un-materialized lazy tree raises** the clear message.
- **`Box.read_data`** returns correct bytes for binary and `FileSlice` leaves.
- **Property (`MP4Builder` + temp file):** build a file, write to a temp path,
  `read(lazy: true, lazy_threshold: small)`; assert lazy serialize == eager
  serialize == original, and lazy-faststart-write == eager-faststart-serialize.

## Project layout (new/changed files)

```
lib/iso_media/file_slice.ex            # NEW: %FileSlice{} + read/1, stream/3
lib/iso_media/lazy_parser.ex           # NEW: parse_file/2 (seeking, top-level-aware)
lib/iso_media/parser.ex                # + :offset option (absolute base offset)
lib/iso_media/layout.ex                # + box_size FileSlice clause
lib/iso_media/serializer.ex            # + materialize/1, stream/2; to_iodata FileSlice guard
lib/iso_media/box.ex                   # + read_data/1
lib/iso_media.ex                       # read/2 :lazy; write/2 streams; serialize/1 materializes
test/iso_media/file_slice_test.exs
test/iso_media/lazy_parser_test.exs
test/iso_media/lazy_roundtrip_test.exs
test/iso_media/lazy_property_test.exs
```

## Out of scope (this phase)

- Lazy handling of *nested* large leaves (none exist in real files; only top-level
  leaves are evaluated against the threshold).
- Buffered/coalesced reads in `LazyParser` (per-box `pread` is fine for now; a
  buffering optimization can come later if metadata parsing is slow).
- Memory-mapping; async/streaming parse of `moov` itself.
- Fragmented MP4 and HEIF (still out of scope from Phase 2).
