# Design: DASH MPD generation (static/VOD, single muxed rendition)

**Date:** 2026-06-07
**Status:** Draft (design phase)
**Builds on:** Phases 1-13 (… fragmenting, CMAF segment emission, TrackInfo, HLS playlists).

## Goal

Generate the DASH MPD (`.mpd` XML) for the CMAF segments — `ISOMedia.dash_manifest(boxes, opts)`
→ the manifest string, and `ISOMedia.write_dash(dir, boxes, opts)` → the bundle
(`manifest.mpd` + `init.mp4` + `seg-N.m4s`). Single muxed `static`/VOD rendition. This is
**Sub-project B2** — the last manifest format; it reuses the HLS-era computations (codecs,
resolution, peak bandwidth, per-`moof` spans) and adds an XML body. Correctness is byte-exact
XML pinned to the fixture, plus a well-formedness re-parse.

## Decisions (from brainstorming)

- **Bespoke zero-dep XML builder.** A small `element(name, attrs, children)` + an attribute
  `escape/1` (`& < > "`) + an ISO-8601 duration helper, producing deterministic 2-space-indented
  output. No new dependency (the library is zero-runtime-dep by design); the MPD is a fixed
  structure with controlled values (codec strings, integers, our filenames), so the escaping
  surface is small and bounded. The escape helper is what satisfies the review's XML concern —
  not a library.
- **`SegmentTemplate` + `SegmentTimeline`.** Per-segment exact durations via `<S d="…"/>` and a
  `media="seg-$Number$.m4s"` template — the modern, broadly-supported CMAF-VOD form. Segment
  naming must be `$Number$`-expressible (the default fits); `SegmentList`+uniform-duration
  (misrepresents varying segments) is rejected.
- **Single muxed Representation.** One `Period`/`AdaptationSet`/`Representation`; `codecs` joins
  all tracks; `mimeType`/`contentType` = `video/mp4` (or `audio/mp4` audio-only, dropping
  `width`/`height`). `timescale` and `<S d>` come from `FragmentIndex.fragment_spans/1`
  (video-preferred, consistent across moofs).
- **Shared `ISOMedia.Manifest`.** The manifest-agnostic computations currently **private in
  `ISOMedia.HLS`** (`track_infos/1`, `codecs/1`, `resolution/1`, `peak_bandwidth/1`) are
  extracted into a new `ISOMedia.Manifest` module; `HLS` is refactored to delegate (guarded by
  its byte-exact tests), and `DASH` consumes the same — so the codec/bandwidth logic has one
  home (standard 7 / DRY), exactly the `ProgressiveBuild` extraction pattern from Phase 10.

## The MPD shape (pinned during implementation)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static" minBufferTime="PT1.5S" mediaPresentationDuration="PT2.000S">
  <Period>
    <AdaptationSet contentType="video" mimeType="video/mp4" segmentAlignment="true" startWithSAP="1">
      <Representation id="1" codecs="avc1.64000a,mp4a.40.2" bandwidth="96392" width="128" height="96">
        <SegmentTemplate timescale="10240" initialization="init.mp4" media="seg-$Number$.m4s" startNumber="1">
          <SegmentTimeline>
            <S d="10240"/>
            <S d="10240"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
```

`mediaPresentationDuration` = total seconds (`sum(duration_ts)/timescale`) as ISO 8601
(`PT<seconds, 3 decimals>S` → `PT2.000S`). `minBufferTime` fixed `PT1.5S`. `profiles` =
`urn:mpeg:dash:profile:isoff-live:2011` with `type="static"` (the standard segmented-VOD combo).

## Components

- **`ISOMedia.Manifest`** (`lib/iso_media/manifest.ex`, new): `track_infos/1` (track-id →
  `%TrackInfo{}`, video first), `codecs/1` (joined codec string), `resolution/1`
  (`"WxH"` | `nil`), `peak_bandwidth/1` (`max_i ceil(bytes_i*8*ts_i / dur_ts_i)` over
  `fragment_spans`). Pure.
- **`ISOMedia.HLS`** (refactor): replace its private `track_infos`/`track_codecs`/`resolution`/
  `peak_bandwidth` with calls to `ISOMedia.Manifest`. Behavior unchanged (byte-exact HLS tests
  are the gate). No public API change.
- **`ISOMedia.DASH`** (`lib/iso_media/dash.ex`):
  - `manifest(boxes, opts)` → validate fragmented (raise identically to `split_segments/1`);
    build the MPD via the XML builder from `Manifest.codecs/resolution/peak_bandwidth` +
    `fragment_spans` (`timescale`, `<S d>`, total duration). Returns the XML string.
  - `write_dash(dir, boxes, opts)` → `File.mkdir_p!`; write `manifest.mpd` (`opts[:manifest_name]`);
    then `ISOMedia.write_segments/3` with a `segment_pattern` derived from `segment_template`
    (so filenames match the manifest). Returns `{:ok, [manifest_path | segment_paths]}`.
  - private XML helpers: `element/3` (open tag + attrs + children/self-close), `attr_escape/1`
    (`&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `"`→`&quot;`), `iso8601_duration/1`.
- **Exposed as** `ISOMedia.dash_manifest/2`, `ISOMedia.write_dash/3`.

## `opts`

`init_name` (`"init.mp4"`), `segment_template` (`"seg-$Number$.m4s"` — the DASH media
template), `manifest_name` (`"manifest.mpd"`). The `$Number$` template is the single source of
naming truth: `write_dash` **derives** the `write_segments` `segment_pattern` from it
(`fn i -> String.replace(segment_template, "$Number$", Integer.to_string(i)) end`), so the
written `seg-N.m4s` always match the manifest's template — one opt, no drift.

## Testing

- **Byte-exact MPD:** `dash_manifest(fragment(read("sample_keyint.mp4"), target_duration: 0.5))`
  equals a pinned string (the structure above with the real `timescale`/`<S d>`/`bandwidth`/
  `codecs`/`width`/`height`/`mediaPresentationDuration`).
- **Well-formedness:** the output parses cleanly via `:xmerl_scan.string/1` (stdlib, in the
  test only) — guards against a malformed tag the byte-exact test might not "notice" as invalid.
- **Escaping unit:** `DASH.attr_escape("a & b < c > d \" e")` → `a &amp; b &lt; c &gt; d &quot; e`
  (even though our real values don't contain these — pins the helper).
- **`write_dash` bundle:** writes `manifest.mpd` + `init.mp4` + `seg-N.m4s`; the manifest
  references `init.mp4`/`seg-$Number$.m4s`; returned paths exist.
- **Audio-only:** `audio/mp4`, `codecs="mp4a.40.2"`, **no** `width`/`height` attributes; valid XML.
- **Raises:** progressive (non-fragmented) input raises `ArgumentError`.
- **HLS refactor guard:** the existing HLS byte-exact tests stay green after `HLS` delegates to
  `ISOMedia.Manifest` (proves the extraction changed nothing).

## Scope boundary (explicit deferrals)

- ABR / multi-`Representation`, demuxed per-track `AdaptationSet`s — needs multiple encodes /
  the composition path.
- Live / `dynamic` MPD (`availabilityStartTime`, `timeShiftBufferDepth`) — `static`/VOD only.
- `SegmentBase` + byte-range single-file addressing — separate-segment layout only.
- Encryption (`ContentProtection`/CENC), trick-mode, subtitles/`accessibility`.
- `BaseURL` rewriting / CDN absolute URLs — relative URIs only.

## Risks

- **XML byte-exactness** (indentation, attribute order, self-closing tags) — pinned by the
  byte-exact test; the deterministic builder (fixed attr order, 2-space indent) makes it stable;
  the `:xmerl_scan` re-parse catches structural malformation independent of exact bytes.
- **Muxed timescale** — `fragment_spans` uses the video-preferred traf, so `timescale`/`<S d>`
  are consistent across moofs; the byte-exact test pins them.
- **HLS extraction regression** — neutralized by running the unchanged HLS byte-exact suite
  after the refactor.
