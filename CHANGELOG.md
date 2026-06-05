# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-05

Initial release.

### Added

- **Tree surgery** — parse any ISOBMFF file (MP4/MOV/M4A/HEIF) into a lossless
  `%ISOMedia.Box{}` tree, navigate/edit/reorder/insert, and re-serialize
  byte-for-byte (`serialize(parse(file)) == file`).
- **faststart** — move `moov` ahead of `mdat` with `stco`/`co64` chunk-offset
  rewriting, including automatic `stco`→`co64` promotion.
- **Lazy file-backed payloads** — `read/2` with `lazy: true` keeps large leaf
  payloads on disk as `FileSlice` references; `write/2` streams them disk→disk so
  files larger than RAM can be processed.
- **Sample index + track extraction** — `samples/2` builds a flat `[%Sample{}]`
  per track (progressive or fragmented); `extract_track/2` demuxes one track.
- **Trim** — time-range, keyframe-aligned, frame-accurate (`elst`),
  interleave-preserving lossless trimming.
- **Concatenate** — lossless end-to-end join of compatible clips.
- **Recursive virtual I/O** — chain `trim`/`extract_track`/`concat`/`fragment`/
  `defragment` in memory with no disk round-trip; bytes match a write+re-read
  between stages.
- **Fragmented MP4** — `defragment/1` (fMP4 → progressive) and `fragment/2`
  (progressive → fMP4), inverses of each other.
- **CMAF segments** — `split_segments/1` and `write_segments/3` emit a CMAF
  init segment plus `.m4s` media segments.

[0.1.0]: https://github.com/bradhanks/iso_media/releases/tag/v0.1.0
