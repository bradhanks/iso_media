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

## Status

Phase 1: lossless tree surgery. The library does **not** yet rewrite absolute
offset tables (`stco`/`co64`) on edit — moving data those tables reference is the
caller's responsibility. See `docs/superpowers/specs/` for the design.
