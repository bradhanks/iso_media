# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **HEVC codec metadata** — `track_info/2` now decodes `hvc1`/`hev1` video tracks, producing
  the RFC 6381 codec string (e.g. `hvc1.1.6.L60.90`); HLS and DASH manifest generation work on
  HEVC content.

## [0.2.0] - 2026-06-07

### Added

- **Track codec metadata** — `track_info/2` decodes a track's codec and media
  metadata into `%ISOMedia.TrackInfo{}`, including the RFC 6381 codec string
  (`avc1.PPCCLL` / `mp4a.40.2`) that streaming manifests require.
- **HLS playlists** — `hls_media_playlist/2`, `hls_master_playlist/2`, and
  `write_hls/3` generate HLS VOD `.m3u8` playlists for the CMAF segments.
- **DASH MPD** — `dash_manifest/2` and `write_dash/3` generate a static/VOD DASH
  `.mpd` (single muxed rendition, `SegmentTemplate` + `SegmentTimeline`) for the
  CMAF segments, via a zero-dependency XML builder.

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

[Unreleased]: https://github.com/bradhanks/iso_media/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/bradhanks/iso_media/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bradhanks/iso_media/releases/tag/v0.1.0
