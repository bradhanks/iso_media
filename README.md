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

## Status

Phase 1: lossless tree surgery. Phase 2: `stco`/`co64` chunk-offset rewriting and
faststart. Offset fixing assumes `mdat` payloads are unchanged (box relocation, not
sample editing) and raises otherwise. **Large files:** the whole file is held in
memory, so faststart requires the file to fit in RAM; lazy/file-backed payloads are
a future phase. Fragmented MP4 and HEIF `iloc` offsets are out of scope.
See `docs/superpowers/specs/` for the designs.
