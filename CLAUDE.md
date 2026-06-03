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

- `ISOMedia` (`lib/iso_media.ex`) — top-level entry point: `parse/2`, `serialize/1`, `read/2` (with `lazy: true` for file-backed payloads), `write/2` (streams the tree to disk, so `FileSlice` payloads are copied disk→disk and never fully materialized; returns `:ok` or `{:error, reason}`).
- `ISOMedia.Box` (`lib/iso_media/box.ex`) — the single generic box struct (`type`, `data`, `children`, `uuid`, `size_mode`) plus immutable navigation (`find`/`find_all`) and editing (`update`/`remove`/`insert`/`replace_data`). Container = `data: nil` + `children`; leaf = `data: binary`. A leaf's `data` may also be a **recursive segment list** `[binary | FileSlice | [segment]]` (concatenated on `read_data/1`); nesting arises when a synthesized `mdat` is resolved as a source for a further operation.
- `ISOMedia.Parser` (`lib/iso_media/parser.ex`) — decodes binary → `[%Box{}]`, handling compact/largesize/size-0 boxes and `uuid` extended types, with an opt-in `:heuristic` for sniffing unknown containers.
- `ISOMedia.Serializer` (`lib/iso_media/serializer.ex`) — rebuilds exact bytes from a box tree via iolists, honoring each box's recorded `size_mode`. `serialize/1` first calls `materialize/1` to read any `FileSlice` payloads into memory; `stream/3` instead writes the tree to a raw `io_device`, streaming `FileSlice` payloads from disk in chunks so large trees are never fully materialized. A leaf may also be a **recursive segment list** `[binary | FileSlice | [segment]]` (each part — including nested lists — materialized on `serialize/1`, streamed in order on `stream/3`; `to_iodata/1` raises on a raw segment list).
- `ISOMedia.Registry` (`lib/iso_media/registry.ex`) — classifies which box types are containers, plus the `looks_like_boxes?/1` heuristic.
- `ISOMedia.FullBox` (`lib/iso_media/full_box.ex`) — version/flags prefix helper shared by FullBox typed views.
- `ISOMedia.Boxes.*` (`lib/iso_media/boxes/`) — typed views layered on known boxes: `FileType` (`ftyp`), `Handler` (`hdlr`), `MovieHeader` (`mvhd`), `TrackHeader` (`tkhd`), `MediaHeader` (`mdhd`) — via `decode/1` → struct and `encode/1` → `%Box{}`, without the core depending on them.
- `ISOMedia.Layout` (`lib/iso_media/layout.ex`) — computes absolute box offsets for the current arrangement (`header_size/1`, `box_size/1`, `top_level_layout/1`); the basis for offset rewriting. `box_size/1` sums the parts of a **recursive segment list** leaf via the shared `segments_size/1`/`segment_size/1` helpers (also used by `MdatSource`, so layout and resolver agree on what a nested list weighs).
- `ISOMedia.Offsets` (`lib/iso_media/offsets.ex`) — `fix_chunk_offsets/1` (per-`mdat` delta remap of `stco`/`co64`, with latched `stco`→`co64` promotion via a layout fixpoint) and `faststart/1` (move `moov` before `mdat`, then fix). Exposed as `ISOMedia.fix_chunk_offsets/1` and `ISOMedia.faststart/1`.
- `ISOMedia.Boxes.ChunkOffset` — typed view for `stco`/`co64`.
- `ISOMedia.Boxes.EditList` (`lib/iso_media/boxes/edit_list.ex`) — typed view for `elst` (`decode/1`/`encode/1`, v0/v1; `segment_duration` is movie-timescale, `media_time` is media-timescale and signed).
- `ISOMedia.FileSlice` (`lib/iso_media/file_slice.ex`) — an inert `{path, offset, length}` reference; a leaf's `data` may be a `FileSlice` instead of a binary so bulk payloads stay on disk. `read/1` and `stream/3` (raw `:file` I/O, leak-safe callback opens).
- `ISOMedia.LazyParser` (`lib/iso_media/lazy_parser.ex`) — `parse_file/2`: seeks the top-level boxes, re-parsing each in-memory box through `Parser` with `offset:` (absolute offsets), emitting a `FileSlice` for any leaf ≥ `:lazy_threshold`. Reached via `ISOMedia.read(path, lazy: true)`.
- `ISOMedia.Sample` (`lib/iso_media/sample.ex`) — one decoded sample (`index`, `chunk_index`, `dts`, `duration`, `pts`, `size`, `offset`, `sync?`).
- `ISOMedia.SampleTable` (`lib/iso_media/sample_table.ex`) — `build/1` cross-references a track's `stbl` tables into `[%Sample{}]` (with per-sample `duration` from `stts`); also *encodes* tables from a kept-sample set (`build_stts/build_stsz/build_ctts/build_stss/build_stsc`). Reached via `ISOMedia.samples/2` for **progressive** files (fragmented files dispatch to `FragmentIndex`).
- `ISOMedia.Extract` (`lib/iso_media/extract.ex`) — `track_ids/1`, `find_trak/2`, and `extract_track/2` (rebuilds `mdat` as a segment list + recomputes chunk offsets). Exposed as `ISOMedia.track_ids/1`, `ISOMedia.samples/2`, `ISOMedia.extract_track/2`.
- `ISOMedia.MdatSource` (`lib/iso_media/mdat_source.ex`) — `collect/1` captures each top-level `mdat`'s absolute `payload_start`/`payload_size` from one `Layout.box_size/1` walk (the single source of truth for offsets, so the resolver can never drift from serialization); `segment/3` resolves an absolute byte range via `relative = offset - payload_start`, slicing a `binary`/`FileSlice` (a physical slice is a local byte provider, `fs.offset + relative`) or **recursing through a nested segment list**. Shared by `Extract`, `Trim`, and `Concat`. Because a synthesized `mdat`'s segment list is itself resolvable, `trim`/`concat`/`extract_track` outputs feed one another **entirely in memory** — no disk round-trip between pipeline stages.
- `ISOMedia.Trim` (`lib/iso_media/trim.ex`) — `trim/3`: time-based lossless trim of all tracks (dts selection + snap-to-keyframe, table rebuild, interleave-preserving segment-list `mdat`, duration updates). Emits a per-track `edts`/`elst` (dropping any inherited `edts`) when the snap-to-keyframe introduces a lead, so presentation is frame-accurate from the requested start. Exposed as `ISOMedia.trim/3`.
- `ISOMedia.Concat` (`lib/iso_media/concat.ex`) — `concat/1`: lossless end-to-end join of N compatible clips (byte-identical `stsd` + matching timescale required); checks compatibility, then delegates assembly to `ProgressiveBuild`. Exposed as `ISOMedia.concat/1`.
- `ISOMedia.ProgressiveBuild` (`lib/iso_media/progressive_build.ex`) — `assemble/4`: shared progressive `[ftyp, moov, mdat]` builder from one or more inputs' per-track `[%Sample{}]` + `mdat` sources. Rebuilds every `stbl` table via `SampleTable.build_*` + `ChunkOffset`, preserves interleave (runs sorted by original offset) while keeping logical `{input, chunk}` order for each track's `stco`. Used by `Concat` (N inputs) and `Defragment` (one input).
- `ISOMedia.Boxes.{TrackExtends, TrackFragmentHeader, TrackFragmentDecodeTime, TrackRun}` — decode-only typed views for the fMP4 boxes `trex`/`tfhd`/`tfdt`/`trun` (flag-gated fields; `trun` v1 signed composition offsets).
- `ISOMedia.FragmentIndex` (`lib/iso_media/fragment_index.ex`) — `fragmented?/1` (tree has `mvex` + `moof`) and `samples/2`: indexes a fragmented track into the same `[%Sample{}]` as progressive. One tree-local `Layout` walk stamps each `moof`'s offset; the cascade `trun → tfhd → trex` resolves per-sample duration/size/flags; offsets are moof-relative (`default-base-is-moof`; raises on unsupported addressing or `senc`/`saiz`/`saio`); `dts` from `tfdt` (per-fragment-anchored, cumulative within a traf); `chunk_index` per `trun`. Reached via `ISOMedia.samples/2`, which dispatches here when `fragmented?/1`.
- `ISOMedia.Defragment` (`lib/iso_media/defragment.ex`) — `defragment/1`: repack a fragmented tree into progressive `[ftyp, moov, mdat]` (pure metadata edit, no transcoding). Indexes each track via `FragmentIndex`, strips `mvex`/`moof`, and assembles via `ProgressiveBuild` (so the `mdat` is a segment list referencing each fragment's bytes — memory-safe). Exposed as `ISOMedia.defragment/1`.

The invariant throughout is byte-for-byte round-trip: `ISOMedia.serialize(parse(file)) == file`. This extends to in-memory pipelines: chaining operations without writing intermediates to disk (e.g. `trim |> concat |> trim`) produces bytes identical to running the same stages with a write+re-read between each.

Boxes carry `source_offset`/`source_size` (stamped by the parser) so offset rewriting knows where each `mdat` originally lived; these are metadata and never serialized.

## Design context

`docs/superpowers/specs/` holds design specs when the brainstorming/planning workflow is used — check there for the intended direction before making architectural changes.
