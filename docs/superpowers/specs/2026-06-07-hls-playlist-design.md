# Design: HLS playlist generation (VOD, single muxed rendition)

**Date:** 2026-06-07
**Status:** Draft (design phase)
**Builds on:** Phases 1-12 (… fragmenting, CMAF segment emission, TrackInfo codec metadata).

## Goal

Generate the HLS (`.m3u8`) playlists for the CMAF segments `ISOMedia.split_segments/1`
produces: a **media playlist** (the segment list) and a **multivariant (master) playlist**
(codecs/resolution/bandwidth), for a single muxed VOD rendition. This is **Sub-project B3**
of the DASH/CMAF manifest frontier; DASH (`.mpd`) is a separate later phase. The whole
correctness story is byte-exact text — assert the generated playlist equals the expected
string.

Public API:
- `ISOMedia.hls_media_playlist(boxes, opts \\ [])` → `String.t()` (pure)
- `ISOMedia.hls_master_playlist(boxes, opts \\ [])` → `String.t()` (pure)
- `ISOMedia.write_hls(dir, boxes, opts \\ [])` → writes `master.m3u8` + `media.m3u8` + (via
  `write_segments/3`) `init.mp4` + `seg-N.m4s`; returns `{:ok, paths}`.

## Decisions (from brainstorming)

- **Both playlists, single muxed rendition.** A media playlist alone isn't a complete HLS
  stream (codecs are declared only in the master), so v1 emits both. The muxed segments carry
  all tracks, so it's one variant whose `CODECS` joins every track's codec string.
- **VOD only.** All segments are known up front → `#EXT-X-PLAYLIST-TYPE:VOD` + `#EXT-X-ENDLIST`.
  Live/sliding-window is a different mode, deferred.
- **Input is a `fragment/2`-shaped tree** (`[ftyp, moov, (moof, mdat)+]`); raises otherwise.
  `opts` mirror `write_segments` for naming consistency: `init_name` (`"init.mp4"`),
  `segment_pattern` (`fn i -> "seg-#{i}.m4s" end`), plus `media_uri` (`"media.m3u8"`, the
  master→media link).
- **Per-segment quantities are computed per-`moof`** (each segment = one `moof`+`mdat`), so
  they align with the N segments even if a trailing fragment lacks video.

## Components

`ISOMedia.FragmentIndex.fragment_spans/1` (new, shared) — `fragment_spans(boxes)` →
`[%{duration_ts, timescale, bytes}]`, one entry per `moof` in tree order. For each `moof` it
picks the **video** `traf` (its `tfhd.track_id` matches the `vide`-handler track) or, if the
fragment has none, the first `traf`; resolves that `traf`'s `trun` sample durations via the
existing cascade (`resolve_run`/`trex`/`tfhd` defaults) and sums them → `duration_ts`;
`timescale` is the track's `mdhd` timescale; `bytes` is the sibling `mdat`'s payload size
(`Layout.box_size(mdat) - Layout.header_size(mdat)`). This lives in `FragmentIndex` (which
already owns the `moof`/`traf`/`trun` cascade) so the trun-duration summing has **one** home;
`HLS` consumes it and only formats (standard 7 / DRY).

`ISOMedia.HLS` (`lib/iso_media/hls.ex`):

- **`media_playlist(boxes, opts)`** → the media `.m3u8`:
  ```
  #EXTM3U
  #EXT-X-VERSION:7
  #EXT-X-PLAYLIST-TYPE:VOD
  #EXT-X-TARGETDURATION:<ceil(max segment seconds)>
  #EXT-X-MAP:URI="<init_name>"
  #EXTINF:<seg seconds, 3 decimals>,
  <segment_pattern.(1)>
  …
  #EXT-X-ENDLIST
  ```
  Lines joined with `\n`, trailing newline.
- **`master_playlist(boxes, opts)`** → the multivariant `.m3u8`:
  ```
  #EXTM3U
  #EXT-X-STREAM-INF:BANDWIDTH=<peak>,CODECS="<c1,c2,…>"[,RESOLUTION=<W>x<H>]
  <media_uri>
  ```
  `RESOLUTION` is included only when there is a video track.
- **`write_hls(dir, boxes, opts)`** → `File.mkdir_p!(dir)`, write `master.m3u8` and
  `media.m3u8`, then `ISOMedia.write_segments(dir, boxes, opts)` for the media files; returns
  `{:ok, [master, media | segment_paths]}`.
- Exposed as `ISOMedia.hls_media_playlist/2`, `hls_master_playlist/2`, `write_hls/3`.

## The computed quantities

Validate the input shape first: it must be `fragment/2`-shaped (`[ftyp, moov, (moof, mdat)+]`),
raising `ArgumentError` identically to `split_segments/1` on anything else. Then walk the
`moof`/`mdat` pairs once, computing per-segment `{duration, bytes}`. The segment count is the
`moof` count (== `length(split_segments(boxes).segments)`).

All per-segment durations and bytes come from `FragmentIndex.fragment_spans(boxes)` (above) —
`HLS` does not walk `moof`s/`trun`s itself.

- **Per-segment duration** (`#EXTINF`, and `TARGETDURATION = ceil(max)`):
  `seconds_i = span.duration_ts / span.timescale`. (`fragment/2` writes all-explicit `trun`
  durations, and the shared resolver also handles defaulted ones.)
- **Per-segment bytes** (for bandwidth): `span.bytes`.
- **`BANDWIDTH`** = the **peak** per-segment bit rate =
  `max_i ceil(span.bytes_i * 8 / seconds_i)`, an integer bits/sec (HLS `BANDWIDTH` is the peak
  segment rate). This is the `bitrate` computation Phase 12 deferred to here.
- **`CODECS`** = each track's `%TrackInfo{}.codec` (via `track_info/2`), video first then
  audio, comma-joined (`"avc1.64000a,mp4a.40.2"`).
- **`RESOLUTION`** = the video `%TrackInfo{}`'s `width` × `height` (`"128x96"`); omitted if
  audio-only.

## Data flow

`read("movie.mp4") |> fragment(target_duration: 4.0)` → `hls_master_playlist` /
`hls_media_playlist` (compute durations/bytes from the `moof`/`mdat` pairs; codecs/resolution
from `track_info/2`) → strings; `write_hls(dir, …)` writes the two playlists + the segments.
The init/segment URIs in the playlists match `write_segments`'s filenames exactly (shared
`opts`), so the written bundle is internally consistent.

## Testing

- **Byte-exact media playlist:** `fragment(read("sample_keyint.mp4"), target_duration: 0.5)`
  → `hls_media_playlist` equals a pinned string (header, `EXT-X-MAP`, one `EXTINF`+URI per
  segment with the real durations, `ENDLIST`). Assert `TARGETDURATION` = `ceil(max EXTINF)`.
- **Byte-exact master playlist:** `hls_master_playlist` equals a pinned string with the real
  `CODECS="avc1.64000a,mp4a.40.2"`, `RESOLUTION=128x96`, and the computed `BANDWIDTH`.
- **Segment count + URI consistency:** `EXTINF` count == `moof` count == `length(segments)`;
  every segment URI in the media playlist matches a file `write_hls` writes.
- **`write_hls` bundle:** writes `master.m3u8`, `media.m3u8`, `init.mp4`, `seg-N.m4s`; the
  master references `media.m3u8`, the media references `init.mp4` + each `seg-N.m4s`, and all
  referenced files exist; returned paths are correct.
- **Custom opts:** `segment_pattern`/`init_name`/`media_uri` flow through to both playlists
  and the written files consistently.
- **Audio-only:** `fragment(read("sample.m4a"))` → master has `CODECS="mp4a.40.2"` and **no**
  `RESOLUTION`; media playlist still well-formed.
- **Raises:** progressive (non-fragmented) input raises `ArgumentError`.

## Scope boundary (explicit deferrals)

- DASH `.mpd` — separate phase (B2).
- ABR / multi-bitrate variants (multiple `#EXT-X-STREAM-INF`) — needs multiple encodes we
  don't produce.
- Demuxed per-track playlists + `#EXT-X-MEDIA` audio groups — we emit muxed segments; per-track
  is the composition path.
- Live / event playlists (`#EXT-X-MEDIA-SEQUENCE`, no `ENDLIST`), I-frame playlists
  (`#EXT-X-I-FRAME-STREAM-INF`), encryption (`#EXT-X-KEY`), subtitles/`#EXT-X-MEDIA` text.

## Risks

- **Per-segment duration alignment** — neutralized by computing per-`moof` (not via a track's
  chunk grouping), so N durations always match N segments; covered by the segment-count test.
- **Float formatting of `EXTINF`** — pin to 3 decimals (`:erlang.float_to_binary(s, decimals: 3)`
  or equivalent) so the byte-exact tests are stable across platforms.
- **`BANDWIDTH` rounding** — defined as `ceil` of the peak segment rate; pinned by the master
  test so the exact integer is locked.
