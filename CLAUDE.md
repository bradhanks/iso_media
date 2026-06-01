# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`iso_media` is an Elixir library for parsing the **ISO Base Media File Format** (ISOBMFF, ISO/IEC 14496-12) — the box/atom container format underlying MP4, MOV, M4A, HEIF, and related formats. The goal is to decompose any ISO media file into its constituent boxes, expose the parts, and re-serialize them back into a valid file.

The core is built around a single generic `%ISOMedia.Box{}` struct: a parser decodes binary into a lossless tree of boxes, a serializer rebuilds the exact bytes, and the public API offers immutable navigation/editing plus typed views for well-known boxes.

## Commands

```sh
mix deps.get              # fetch dependencies
mix compile               # compile
mix test                  # run all tests
mix test test/iso_media_test.exs:5   # run a single test by file:line
mix format                # format per .formatter.exs
```

## Architecture

ISOBMFF files are a flat-then-nested sequence of **boxes** (a.k.a. atoms). Each box is: a 32-bit size, a 4-char type tag, then either child boxes (container boxes) or type-specific payload (leaf boxes). The model mirrors this tree:

- `ISOMedia` (`lib/iso_media.ex`) — top-level entry point: `parse/2`, `serialize/1`, `read/2`, `write/2`.
- `ISOMedia.Box` (`lib/iso_media/box.ex`) — the single generic box struct (`type`, `data`, `children`, `uuid`, `size_mode`) plus immutable navigation (`find`/`find_all`) and editing (`update`/`remove`/`insert`/`replace_data`). Container = `data: nil` + `children`; leaf = `data: binary`.
- `ISOMedia.Parser` (`lib/iso_media/parser.ex`) — decodes binary → `[%Box{}]`, handling compact/largesize/size-0 boxes and `uuid` extended types, with an opt-in `:heuristic` for sniffing unknown containers.
- `ISOMedia.Serializer` (`lib/iso_media/serializer.ex`) — rebuilds exact bytes from a box tree via iolists, honoring each box's recorded `size_mode`.
- `ISOMedia.Registry` (`lib/iso_media/registry.ex`) — classifies which box types are containers, plus the `looks_like_boxes?/1` heuristic.
- `ISOMedia.FullBox` (`lib/iso_media/full_box.ex`) — version/flags prefix helper shared by FullBox typed views.
- `ISOMedia.Boxes.*` (`lib/iso_media/boxes/`) — typed views layered on known boxes (`ftyp`, `hdlr`, `mvhd`, `tkhd`, `mdhd`) via `decode/1` → struct and `encode/1` → `%Box{}`, without the core depending on them.
- `ISOMedia.Layout` (`lib/iso_media/layout.ex`) — computes absolute box offsets for the current arrangement (`header_size/1`, `box_size/1`, `top_level_layout/1`); the basis for offset rewriting.
- `ISOMedia.Offsets` (`lib/iso_media/offsets.ex`) — `fix_chunk_offsets/1` (per-`mdat` delta remap of `stco`/`co64`, with latched `stco`→`co64` promotion via a layout fixpoint) and `faststart/1` (move `moov` before `mdat`, then fix). Exposed as `ISOMedia.fix_chunk_offsets/1` and `ISOMedia.faststart/1`.
- `ISOMedia.Boxes.ChunkOffset` — typed view for `stco`/`co64`.

The invariant throughout is byte-for-byte round-trip: `ISOMedia.serialize(parse(file)) == file`.

Boxes carry `source_offset`/`source_size` (stamped by the parser) so offset rewriting knows where each `mdat` originally lived; these are metadata and never serialized.

## Design context

`docs/superpowers/specs/` holds design specs when the brainstorming/planning workflow is used — check there for the intended direction before making architectural changes.
