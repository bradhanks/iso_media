# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`iso_media` is an Elixir library for parsing the **ISO Base Media File Format** (ISOBMFF, ISO/IEC 14496-12) — the box/atom container format underlying MP4, MOV, M4A, HEIF, and related formats. The goal is to decompose any ISO media file into its constituent boxes, expose the parts, and re-serialize them back into a valid file.

The project is at an **early skeleton stage**: the box hierarchy is being sketched out and parsing/serialization is incomplete. Treat existing modules as a starting point, not a working baseline (see Known issues).

## Commands

```sh
mix deps.get              # fetch dependencies
mix compile               # compile
mix test                  # run all tests
mix test test/iso_media_test.exs:5   # run a single test by file:line
mix format                # format per .formatter.exs
```

## Architecture

ISOBMFF files are a flat-then-nested sequence of **boxes** (a.k.a. atoms). Each box is: a 32-bit size, a 4-char type tag, then either child boxes (container boxes) or type-specific payload (leaf boxes). The intended model mirrors this tree:

- `ISOMedia` (`lib/iso_media.ex`) — top-level entry point (currently a placeholder).
- `ISOMedia.FileTypeBox` (`lib/iso_media/file_type_box.ex`) — the `ftyp` box: `major_brand`, `minor_version`, `compatible_brands`. Has a `from_binary/1` parser.
- `ISOMedia.MovieBox` (`lib/iso_media/movie_box.ex`) — the `moov` box and its nested children (`mvhd`, `trak`/`TrakBox`, `mvex`, `mdia`, etc.), defined as embedded schemas.

Note the layout split: `lib/core/` and `lib/iso_media/` both exist; box modules currently live under `lib/iso_media/`.

A box type's spec metadata (container, mandatory, quantity) is documented in comments above each module, taken from the ISOBMFF standard — preserve and follow these when implementing.

## Known issues / gotchas

These are real bugs in the current skeleton — fix as you encounter them rather than building on top of them:

- **Module name inconsistency:** modules are defined as `ISOMedia.*`, but tests and docs reference `IsoMedia.*`. Pick one (the OTP app is `:iso_media`).
- **Ecto is used but undeclared:** `movie_box.ex` and `file_type_box.ex` `use Ecto.Schema` / `import Ecto.Changeset`, but the only dependency in `mix.exs` is `:fs`. Either add `:ecto` or move off Ecto. Whether Ecto is even the right abstraction for arbitrary boxes is an open design question.
- **`file_type_box.ex` changeset** references an undefined `file_type` variable (should be the function arg) and the `from_binary/1` integer/brand slicing logic is incorrect for the binary layout.
- **Duplicate module definition:** `ISOMedia.MovieBox.TrackBox` is defined twice in `movie_box.ex`.

## Design context

`docs/superpowers/specs/` holds design specs when the brainstorming/planning workflow is used — check there for the intended direction before making architectural changes.
