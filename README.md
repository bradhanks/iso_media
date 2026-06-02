# ISOMedia

Lossless ISOBMFF (MP4 / MOV / M4A / HEIF) box surgery in pure Elixir.

Parse any ISO Base Media file into a tree of boxes — every box, including
unknown/vendor boxes, preserved byte-for-byte — then navigate, extract, reorder,
insert, edit, and re-serialize.

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")

# inspect
ISOMedia.Box.find(boxes, ~w(moov mvhd))
ISOMedia.Boxes.FileType.decode(ISOMedia.Box.find(boxes, ~w(ftyp)))

# edit (immutable — returns a new tree)
boxes = ISOMedia.Box.remove(boxes, ~w(moov udta))

# write back out
ISOMedia.write("out.mp4", boxes)
```

## faststart

Move `moov` ahead of `mdat` so the file can start playing before it's fully
downloaded, with chunk offsets recomputed automatically:

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")
ISOMedia.write("movie.faststart.mp4", ISOMedia.faststart(boxes))
```

`ISOMedia.fix_chunk_offsets/1` is the underlying primitive: rearrange boxes however
you like, then call it to repair `stco`/`co64` (it auto-promotes `stco`→`co64` when
an offset exceeds 32 bits).

## Large files (lazy payloads)

Process files bigger than RAM: parse keeps big leaf payloads (`mdat`) as on-disk
references, and `write/2` streams them disk→disk.

```elixir
{:ok, boxes} = ISOMedia.read("huge.mp4", lazy: true)   # mdat stays on disk
ISOMedia.write("huge.faststart.mp4", ISOMedia.faststart(boxes))  # streamed out
```

Peak memory is roughly the metadata (`moov`) plus one stream chunk, independent of
file size. `serialize/1` instead reads slices into memory (use it only for small
trees). You must not `write/2` to a file you're reading from (it raises). The source
file must stay put until the write completes.

`write/2` returns `:ok` on success or `{:error, reason}` if the output file cannot be
opened; it may raise on a mid-stream I/O error (e.g. disk full).

## Sample-level access

Read a track's samples, or demux a single track into its own file:

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")
ISOMedia.track_ids(boxes)            # => [1, 2]
ISOMedia.samples(boxes, 1)           # => [%ISOMedia.Sample{dts:, pts:, size:, offset:, sync?:, ...}, ...]

# Extract just track 1 (rebuilds mdat + chunk offsets; streams the media disk→disk under lazy:)
ISOMedia.write("track1.mp4", ISOMedia.extract_track(boxes, 1))
```

Extraction preserves the track's existing sample tables and chunking; it rebuilds
only `mdat` and `stco`/`co64`. The result is already in faststart order
(`ftyp`/`moov`/`mdat`) with a freshly synthesized `mdat`, so `faststart/1` and
`fix_chunk_offsets/1` cannot be re-applied to it (they reject synthesized `mdat`s);
run faststart on the source *before* extracting if you need a custom order.
Movie/track `mvhd`/`tkhd` durations are left as-is. `stz2` sample sizes are not yet
supported (raises). Trim and concatenation are future phases.

## Status

Phase 1: lossless tree surgery. Phase 2: `stco`/`co64` chunk-offset rewriting and
faststart. Phase 3: lazy file-backed payloads for files larger than memory. Offset
fixing assumes `mdat` payloads are unchanged (box relocation, not sample editing).
Fragmented MP4 and HEIF `iloc` offsets remain out of scope. See
`docs/superpowers/specs/` for the designs.
