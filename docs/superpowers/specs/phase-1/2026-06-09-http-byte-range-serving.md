# Phase 1 — HTTP Byte-Range Serving (`ISOMedia.HTTP`)

**Feature:** `http-byte-range-serving`
**Source spec:** `docs/superpowers/specs/2026-06-09-http-byte-range-serving-design.md`
**Phase:** 1 of 1 (single atomic phase)
**Date:** 2026-06-09

## Phase metadata

- **Number:** 1
- **Short title:** Pure HTTP-semantics layer (`ISOMedia.HTTP.*`) over `SeekIndex` — Range /
  conditional / multipart / ETag / content-type — plus an optional compile-guarded
  `ISOMedia.Plug` reference adapter.

## Decomposition rationale (null hypothesis)

This feature is delivered as a **single atomic phase**. The null hypothesis holds: there is
no genuine deploy/data-safety risk that a split would reduce.

- `iso_media` is a pure, zero-runtime-dependency, in-memory binary-parsing library. `ISOMedia.HTTP`
  is a pure HTTP-semantics layer that produces *plans* (`%Response{}`) and *lazy bodies*
  (`Stream`s over the already-shipped `SeekIndex.stream_range`). Nothing opens a socket; nothing
  holds persistent state.
- **No migrations**, no backfills, no schema, no persistent state, no deploy-ordering
  constraints, and no external consumers being cut over. The whole deliverable is library code
  verified by `mix test`.
- The five `ISOMedia.HTTP.*` units (`Range`, `Conditional`, `Resource`, `Request`, `Response`)
  are **mutually dependent and co-verified**: `serve/2` orchestrates all of them, and the
  property suite (spec §7) proves every body path against the **single trusted oracle**
  `serialize/1`. There is no "half" of this that is independently shippable-and-verifiable —
  `Range` without `serve/2` answers no request; `serve/2` without `Range`/`Conditional` is
  incomplete. They are co-verified, not sequentially de-risked.
- The **optional `ISOMedia.Plug`** is the only thing resembling an external integration, but it
  is *not* a deploy-ordering boundary: it is compiled only when `Plug.Conn` is loaded
  (`Code.ensure_loaded?/1`), declared `{:plug, "~> 1.0", optional: true}`, never required at
  runtime, and its tests (`Plug.Test`) hit the **same** `serialize/1` oracles as the pure layer.
  It de-risks nothing to ship separately; it is a thin adapter over the same `serve/2`.
- The deliverables *do* have an internal build/compile order (`Range` and `Conditional` are
  prerequisites of `serve/2`; `Resource`/`Response` underpin body streaming) — but that is a
  *within-phase TDD ordering*, not a cross-phase deploy/verification boundary.

Splitting would add ceremony with zero risk reduction. **One atomic phase.**

## Scope boundary

**In scope (everything in the design spec §1–§9):**

- **`ISOMedia.HTTP.Range`** (`lib/iso_media/http/range.ex`, spec §4.1) — RFC 7233
  `parse(header, total, opts) :: {:ok, [{first, last}]} | :unsatisfiable | :ignore`: case-insensitive
  `bytes=` unit gate; `first-last` / `first-` (open) / `-suffix` forms with OWS tolerance;
  per-spec normalization & clamping against `total`; syntactic garbage ⇒ `:ignore` the whole
  header (RFC 7233 §2.1); satisfiability fold; `:coalesce` (default on, sort + merge
  overlapping/adjacent); `:max_ranges` DoS cap (default **100**, over-cap ⇒ `:ignore`).
- **`ISOMedia.HTTP.Conditional`** (`lib/iso_media/http/conditional.ex`, spec §4.2) — RFC 7232 §6
  precedence engine: `evaluate(Request, Resource) :: :proceed | :not_modified | :precondition_failed`
  and `if_range_satisfied?/2`. Strong-vs-weak entity-tag compare (comma-lists + `*`); IMF-fixdate
  parse tolerating obsolete RFC-850 / asctime; `last_modified == nil` ⇒ date conditions cannot fire.
- **`ISOMedia.HTTP.Resource`** (struct, spec §3.2/§4.7) — the cacheable precomputed unit
  (`index`, `etag`, `last_modified`, `content_type`, `content_length`), built once per
  `(file, validator)` and reused across thousands of range requests.
- **`ISOMedia.HTTP.Request`** (struct, spec §3.2) — normalized inbound shape
  (`method`, `range`, `if_match`, `if_none_match`, `if_modified_since`, `if_unmodified_since`,
  `if_range`).
- **`ISOMedia.HTTP.Response`** (struct, spec §3.2/§4.5) — `status` + lowercased-key `headers` +
  pattern-matchable `body` spec (`:empty | {:full, idx} | {:range, idx, off, len} |
  {:multipart, boundary, parts, idx}`).
- **`ISOMedia.HTTP` facade** (`lib/iso_media/http.ex`, spec §3.3) — `resource/2`, `from_headers/2`,
  `serve/2`, `body_stream/2` (lazy, O(range), leak-safe over `SeekIndex.stream_range`),
  `body_iodata/1` (materialized; small/test), `etag/2`, `content_type/1`. Houses the
  `Resource`/`Request`/`Response` structs.
- **`serve/2` orchestration** (spec §4.3) — method gate (405 `allow: GET, HEAD`, configurable
  `:methods`); `Conditional.evaluate` → 412 / 304 / proceed; If-Range gate; `Range.parse` →
  200 full / 416 / 206 single / 206 multipart; HEAD coerces body to `:empty` with identical
  status+headers.
- **Header matrix** (spec §4.4) — exact per-status headers; `accept-ranges: bytes` on every
  200/206; pass-through `:cache_control` / `:extra_headers` merge.
- **Multipart** (spec §4.5) — deterministic, CRLF-free boundary
  `"ISOMedia" <> Base.encode16(:erlang.md5(etag <> :erlang.term_to_binary(ranges)), case: :lower)`;
  precomputed per-part preamble emitted by the stream **and** summed for the exact
  `content-length` (header == streamed bytes by construction); epilogue `--BOUNDARY--CRLF`.
- **`content_type/1`** (spec §4.6) — ordered derivation: `styp` ⇒ `video/iso.segment`; `qt  ` ⇒
  `video/quicktime`; HEIF brands ⇒ `image/heic`; `avif` ⇒ `image/avif`; any `vide` ⇒ `video/mp4`;
  audio-only ⇒ `audio/mp4`; else `application/mp4`. `opts[:content_type]` overrides;
  `opts[:codecs]` appends `; codecs="…"` via `ISOMedia.Manifest.codecs/1`.
- **`etag/2`** (spec §4.7) — `:pure` default (fold `{path,offset,length}` per `{:slice,_}` +
  `:erlang.md5` of each `{:bytes,_}` over the `SeekIndex` descriptors; no payload I/O; strong
  validator under the immutability contract) and `:stat` (additionally fold `mtime`+`size` per
  distinct slice path; weak `W/` tag).
- **Optional `ISOMedia.Plug`** (`lib/iso_media/plug.ex`, spec §5) — guarded by
  `Code.ensure_loaded?(Plug.Conn)`; `@behaviour Plug`; init opts `:resolver | :root`, `:lazy`,
  `:cache (:none | :persistent_term)`, `:chunk_size`, `:methods`, `:etag`, `:cache_control`,
  `:extra_headers`. `call/2`: resolve → build/cache `%Resource{}` → `from_headers` → `serve/2` →
  merge headers + `put_status` → body (`:empty` ⇒ `send_resp(_, _, "")`; otherwise
  `send_chunked/2` + `body_stream/2 |> Enum.reduce_while(conn, &chunk/2)`). Disconnect contract:
  `{:error, :closed}` halts the reduce; `Stream.resource`'s `after_fun` closes any open fd.
- **`ISOMedia` facade re-exports** (spec §3 / §8) — `resource/2`, `serve/2`, `from_headers/2`,
  `etag/2`, `content_type/1`, `body_stream/2`, `body_iodata/1` for parity with the existing
  `read_range/3` facade.
- **`mix.exs`** (spec §8/§9) — add `{:plug, "~> 1.0", optional: true}`; `Plug.Test` available in
  the test environment only.
- **Docs** — CLAUDE.md module-map entries for `ISOMedia.HTTP` and the optional `ISOMedia.Plug`;
  ROADMAP move H1 from horizon to "Shipped".

**Deferred (explicit non-goals, per spec §2):**

- **No transcoding / re-encoding** — H1 serves the bytes a tree *would* serialize to; it never
  rewrites payload.
- **No caching policy** (`Cache-Control` freshness, `Expires`, CORS) beyond a pass-through opt —
  H1 supplies validators (`ETag`/`Last-Modified`), not freshness policy.
- **No content negotiation** between mp4/HLS/DASH — that is the variant/manifest layer (H3).
- **No transfer-encoding decision** — H1 returns a body spec + exact length; the web framework
  chooses chunked vs. content-length framing.
- **No bundled HTTP server / Bandit / Phoenix dependency** — only the optional, compile-guarded
  `ISOMedia.Plug` reference adapter; the core stays zero-runtime-dependency.

## Migrations

**None.** This is a pure in-memory binary-parsing library with no database, no schema, no
persistent state, and no backfill of any kind.

## Domain & API

Pure functions and module boundaries delivered this phase (spec §3.3 / §8):

```elixir
ISOMedia.HTTP.resource(tree | SeekIndex.t(), opts) :: Resource.t()
  # opts: :etag (:pure | :stat), :last_modified, :content_type, :weak, :codecs,
  #       :max_ranges, :coalesce, :cache_control, :extra_headers
ISOMedia.HTTP.from_headers(headers :: map | [{binary, binary}], method) :: Request.t()
ISOMedia.HTTP.serve(Resource.t(), Request.t()) :: Response.t()
ISOMedia.HTTP.body_stream(Response.t(), chunk_size \\ 65_536) :: Enumerable.t()
ISOMedia.HTTP.body_iodata(Response.t()) :: iodata()
ISOMedia.HTTP.etag(tree | SeekIndex.t(), opts) :: binary()
ISOMedia.HTTP.content_type(tree) :: binary()
```

- **New modules:** `ISOMedia.HTTP` (facade + `Resource`/`Request`/`Response` structs),
  `ISOMedia.HTTP.Range`, `ISOMedia.HTTP.Conditional`, and the optional `ISOMedia.Plug`.
- **`serve/2` does zero payload I/O** — it builds a plan; the only metadata I/O is `:stat`-mode
  `resource/2` (build-time, fails loud on a missing backing file). Payload I/O surfaces only in
  `body_stream` as raises from `SeekIndex.stream_range`.
- **Reuse (unchanged):** `ISOMedia.SeekIndex` (`build/1`, `content_length/1`, `read_range/3`,
  `stream_range/4` — the O(range) leak-safe substrate); `ISOMedia.Manifest.codecs/1` (for the
  `; codecs="…"` content-type suffix); `Base`, `:calendar`, and the `:erlang.md5` BIF (zero-dep,
  no `:crypto` application). The core parser / Serializer / Registry are untouched — the
  byte-for-byte round-trip invariant is preserved because every body path resolves through
  `SeekIndex`, which is itself proved byte-exact against `serialize/1`.

**Error-handling contract (spec §6):** untrusted input never raises — every header parse (Range,
HTTP-date, entity-tag, method) returns data; malformed ⇒ safe downgrade (`:ignore` → 200, or a
condition treated as absent). Programmer misuse raises `ArgumentError`. No silent truncation:
`content-length` is computed to equal the streamed bytes, so a short read raises (tears the
connection down) rather than completing a poisoned partial 200/206.

## UI & components

**None.** This library has no UI, no LiveView, no components, no templates. The only
transport-facing surface is the *optional* `ISOMedia.Plug` reference adapter (compiled only when
Plug is present), which is an HTTP adapter, not a UI.

## Testing criteria

Plain ExUnit (unit + property), `stream_data` driving the properties (already a test dep), with
the trusted `serialize/1` as the oracle for every body path. Tests live under
`test/iso_media/http/` mirroring spec §7. Per the repo's TDD discipline, write the property
oracles before the slice/preamble logic so off-by-one and length-mismatch bugs surface
immediately. Scratch-file tests use `@tag :tmp_dir` for `async`-safe isolation.

The full invariant matrix (spec §7) and what "done" means:

1. **Range fidelity** — 206 single body == `binary_part(serialize(tree), clamp(o, len))`
   (property over tree/offset/length).
2. **Full == serialize** — 200 body == `serialize(tree)` (property).
3. **Multipart reassembly** — split body on the boundary; each part's bytes == its `serialize`
   slice; parts cover exactly the coalesced request (property).
4. **Content-Length exactness** — `content-length` header == Σ chunk sizes from `body_stream`
   for 200, 206 single, and 206 multipart (property; the same preamble binaries are summed and
   streamed, so equality holds by construction).
5. **stream == iodata** — `body_stream |> Enum.into("") == body_iodata` for every body spec
   (property).
6. **Conditional precedence** — the full RFC 7232 §6 matrix (presence × match × method) → exact
   status (table-driven).
7. **ETag stability / sensitivity** — same tree ⇒ same tag; changed ⇒ different; `:stat` reacts
   to mtime, `:pure` does not (golden + property).
8. **Range parser never raises** — arbitrary header strings → only `{:ok,_} | :unsatisfiable |
   :ignore`; satisfiable ranges ⊆ `[0, total)` (StreamData fuzz).
9. **416** — fully-out-of-range ⇒ 416 + `content-range: bytes */total` (cases).
10. **HEAD parity** — HEAD headers == GET headers, body empty (property).
11. **End-to-end Plug** *(only when Plug is loaded)* — `Plug.Test` conn → `call/2` → the same
    oracles, including range / conditional / multipart, plus the disconnect/fd-cleanup path
    (integration).
12. **Content-Type golden** — mp4 / mov / m4a / heic / segment corpus → expected type (golden).

**Done** = the full property matrix (1–10, 12) holds across the fixture matrix; the Plug
integration (11) passes when Plug is loaded **and** the core compiles/tests green with Plug
absent (zero-dep guarantee intact); `mix format` clean; the byte-for-byte round-trip invariant
preserved (every body path equals the corresponding `serialize/1` slice).

## Dependencies

None on other phases — this is the single, self-contained phase for the feature. It builds only
on already-shipped library internals: `ISOMedia.SeekIndex` (`build/1`, `content_length/1`,
`read_range/3`, `stream_range/4`) and `FileSlice` from the **virtual-seekable-media** phase,
`ISOMedia.Manifest.codecs/1`, the byte-exact `serialize/1` oracle, and OTP/Elixir stdlib
(`Base`, `:calendar`, `:erlang.md5`). `{:plug, "~> 1.0", optional: true}` is the sole new
declaration and is never required at runtime.
