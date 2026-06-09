# HTTP Byte-Range Serving (`ISOMedia.HTTP`) — Design

**Date:** 2026-06-09
**Status:** Approved (pending spec review)
**Source idea:** Roadmap horizon **H1** — the pure HTTP-serving substrate over the just-landed virtual-seek layer (`SeekIndex`/`read_range`/`stream_range`/`content_length`).

## 1. Context & motivation

`iso_media` can already build a transform tree in memory and answer random-access reads
over its *would-be* serialization without materializing it: `ISOMedia.SeekIndex` provides
`content_length/1`, `read_range/3`, and a leak-safe, O(range) `stream_range/4`. What is
missing is the **HTTP semantics layer** that turns "give me bytes `[o, o+len)` of this tree"
into a correct HTTP response: `Range` parsing, conditional requests, `multipart/byteranges`,
content typing, and the validators (`ETag`/`Last-Modified`) a cache needs.

H1 is that layer. It is **pure and zero-runtime-dependency**: it produces *plans*
(`%Response{}`) and *lazy bodies* (`Stream`s over `SeekIndex.stream_range`) that any web
framework renders. It is the substrate the future media server (and the LiveView showcase)
calls into; nothing in the core knows HTTP transport, Plug, or Phoenix exist. A thin,
**optional** `ISOMedia.Plug` — compiled only when Plug is available — is the zero-friction
adoption surface for Phoenix/Bandit users without touching the core's zero-dep guarantee.

Guiding invariants, unchanged: **byte-for-byte round-trip** (everything is provable against
the trusted `serialize/1`) and **zero runtime dependencies** in the core.

## 2. Goals & non-goals

### Goals

- `ISOMedia.HTTP.Range` — RFC 7233 parsing: single/multi/suffix/open ranges, coalescing,
  satisfiability folding, and a configurable `max_ranges` DoS cap.
- `ISOMedia.HTTP.Conditional` — the RFC 7232 §6 precedence engine for
  `If-Match`/`If-None-Match`/`If-Modified-Since`/`If-Unmodified-Since`/`If-Range`, with
  correct strong-vs-weak entity-tag comparison.
- `ISOMedia.HTTP.Resource` — the cacheable, precomputed unit: `SeekIndex` + `etag` +
  `last_modified` + `content_type` + `content_length`. Built once, reused across thousands
  of range requests; this is where the O(range)-per-request economics live.
- `ISOMedia.HTTP.Request` — the normalized inbound shape (`method` + `range` + `if_*`).
- `ISOMedia.HTTP.Response` — `status` + `headers` + a pattern-matchable `body` spec, plus
  `body_stream/2` (lazy, O(range), leak-safe) and `body_iodata/1` (materialized; small/test).
- A configurable `etag/1`: a **pure** default (no file I/O, strong validator under the
  `SeekIndex` immutability contract) and an opt-in `:stat` mode (folds mtime+size, weak tag).
- `content_type/1` derivation from `ftyp` brands + codecs + handler types.
- An **optional** `ISOMedia.Plug` reference adapter.
- A property-test suite that locks every guarantee against `serialize/1`.

### Non-goals

- **No transcoding / re-encoding** — H1 serves the bytes a tree *would* serialize to.
- **No caching policy** (`Cache-Control`, `Expires`, CORS) beyond a pass-through opt — that
  is the server/consumer's concern. H1 supplies validators; it does not set freshness policy.
- **No content negotiation** between mp4/HLS/DASH — that is the variant/manifest layer (H3).
- **No transfer-encoding decisions** — H1 hands back a body spec + exact length; the web
  framework chooses chunked vs. content-length framing.

### Contracts the caller owns

- **Backing files are immutable for the `Resource`'s lifetime** (the same contract
  `SeekIndex` already documents). The pure `etag` is a strong validator only under this
  contract; callers who cannot guarantee it should use `:stat` mode.

## 3. Architecture

Five small, single-purpose units under `ISOMedia.HTTP.*`, plus one optional Plug. The core
is pure; nothing opens a socket.

```
ISOMedia.HTTP            facade: resource/2, serve/2, from_headers/2, etag/2, content_type/1,
│                                body_stream/2, body_iodata/1
├── .Resource            precomputed: index, etag, last_modified, content_type, content_length
├── .Request             normalized inbound: method, range, if_* validators
├── .Range               RFC 7233 parse/coalesce/validate → byte ranges
├── .Conditional         RFC 7232 §6 precedence → :proceed | :not_modified | :precondition_failed
├── .Response            status + headers + body spec; body_stream/2 + body_iodata/1
└── (optional) ISOMedia.Plug   compiled only if Plug is loaded — the adoption surface
```

The same public functions are re-exported on `ISOMedia` for parity with the existing facade
(`ISOMedia.read_range/3` etc.).

### 3.1 Data flow (one request)

```
tree ──resource/2──▶ %Resource{}   (built once; cache & reuse across requests)
                          │
conn headers ─from_headers/2─▶ %Request{}
                          │
        serve(resource, request)
                          ▼
        Conditional.evaluate ──┬─ :not_modified ──────▶ 304 (validators, :empty)
                               ├─ :precondition_failed ▶ 412 (validators, :empty)
                               └─ :proceed ─▶ (If-Range gate) ─▶ Range.parse ──┬─ :ignore ───▶ 200 {:full}
                                                                               ├─ :unsatisfiable ▶ 416
                                                                               ├─ [one] ─────▶ 206 {:range}
                                                                               └─ [many] ────▶ 206 {:multipart}
                          ▼
                   %Response{status, headers, body}
                          │
   body_stream(resp, chunk) ─▶ lazy Enumerable interleaving preamble bytes + SeekIndex.stream_range
   body_iodata(resp)        ─▶ materialized (small / test path)
```

### 3.2 Key types

```elixir
%ISOMedia.HTTP.Resource{
  index           :: SeekIndex.t(),
  etag            :: binary,             # ~s("a1b2…") or ~s(W/"…")
  last_modified   :: :calendar.datetime() | nil,
  content_type    :: binary,             # "video/mp4" | "audio/mp4" | "image/heic" | …
  content_length  :: non_neg_integer()   # = SeekIndex.content_length/1
}

%ISOMedia.HTTP.Request{
  method              :: :get | :head | :other,
  range               :: binary | nil,
  if_none_match       :: binary | nil,
  if_match            :: binary | nil,
  if_modified_since   :: binary | nil,
  if_unmodified_since :: binary | nil,
  if_range            :: binary | nil
}

%ISOMedia.HTTP.Response{
  status  :: 200 | 206 | 304 | 405 | 412 | 416,
  headers :: [{binary, binary}],         # lowercased keys, ready to merge onto conn
  body    :: :empty
           | {:full, SeekIndex.t()}
           | {:range, SeekIndex.t(), offset :: non_neg_integer(), length :: non_neg_integer()}
           | {:multipart, boundary :: binary, [part], SeekIndex.t()}
}

# part :: %{content_type: binary, first: non_neg_integer(), last: non_neg_integer(),
#           preamble: binary}   # preamble precomputed during serve/2 (see §4.5)
```

### 3.3 Public surface

```elixir
ISOMedia.HTTP.resource(tree | SeekIndex.t(), opts) :: Resource.t()
  # opts: :etag (:pure | :stat), :last_modified, :content_type, :weak, :codecs,
  #       :max_ranges, :coalesce, :cache_control, :extra_headers
ISOMedia.HTTP.from_headers(headers :: map | [{binary, binary}], method) :: Request.t()
ISOMedia.HTTP.serve(Resource.t(), Request.t()) :: Response.t()
ISOMedia.HTTP.body_stream(Response.t(), chunk_size \\ 65_536) :: Enumerable.t()
ISOMedia.HTTP.body_iodata(Response.t()) :: iodata()
ISOMedia.HTTP.etag(tree | SeekIndex.t(), opts) :: binary()      # standalone cache key
ISOMedia.HTTP.content_type(tree) :: binary()
```

`Resource` is the cache unit: build once per `(file, validator)` and reuse — the marginal
cost of a range request is then only `Request` parsing + struct allocation.

## 4. HTTP semantics

### 4.1 `Range` — RFC 7233 parsing

```elixir
parse(header :: binary, total :: non_neg_integer(), opts) ::
    {:ok, [{first, last}]}    # normalized, inclusive, absolute, sorted, coalesced
  | :unsatisfiable            # → 416
  | :ignore                   # → 200 full
```

Rules, in order:

1. **Unit gate** — must be `bytes=` (case-insensitive token). Any other unit → `:ignore`.
2. **Spec forms** — comma-list of `first-last`, `first-` (open), `-suffix` (last *N* bytes);
   OWS around commas tolerated.
3. **Per-spec normalization against `total`:**
   - `first-last`: require `first ≤ last`; clamp `last` to `total-1`; `first ≥ total` ⇒ unsatisfiable.
   - `first-`: `last = total-1`; `first ≥ total` ⇒ unsatisfiable.
   - `-suffix`: `first = max(0, total-suffix)`, `last = total-1`; `suffix == 0` ⇒ unsatisfiable.
4. **Syntactic garbage** (non-numeric, negative, `last < first`, empty) ⇒ **ignore the whole
   header** (`:ignore` → 200), per RFC 7233 §2.1 guidance.
5. **Satisfiability fold** — drop unsatisfiable specs; if *all* unsatisfiable ⇒ `:unsatisfiable`;
   if ≥1 satisfiable ⇒ keep those.
6. **Coalesce** (`:coalesce`, default on) — sort by `first`, merge overlapping/adjacent
   (`prev.last + 1 ≥ next.first`). Kills range-amplification, shrinks multipart parts.
7. **DoS cap** (`:max_ranges`, default **100**) — coalesced count over the cap ⇒ `:ignore`
   (serve 200), matching nginx/Apache behavior against the Apache Range-header DoS class.

Returned ranges are inclusive absolute `{first, last}`; `serve/2` converts to
`{offset, length}` (`length = last - first + 1`) for `SeekIndex`.

### 4.2 `Conditional` — RFC 7232 §6 precedence

```elixir
evaluate(Request.t(), Resource.t()) :: :proceed | :not_modified | :precondition_failed
if_range_satisfied?(Request.t(), Resource.t()) :: boolean   # consulted only when Range present
```

Evaluation order (short-circuits):

| Step | Condition present | Test | Outcome |
|------|-------------------|------|---------|
| 1 | `If-Match` | strong-compare; `*` = resource exists | no match → **412** |
| 2 | `If-Unmodified-Since` *(only if no `If-Match`)* | `last_modified > date` | modified → **412** |
| 3 | `If-None-Match` | weak-compare; `*` = exists | match + GET/HEAD → **304**; match + other → **412** |
| 4 | `If-Modified-Since` *(only if no `If-None-Match`, GET/HEAD)* | `last_modified ≤ date` | not modified → **304** |
| 5 | `If-Range` *(only with Range)* | strong etag-compare **or** exact date | mismatch → ignore Range → **200** |

- **Entity-tag compare:** *strong* = both un-weak and octet-equal (`If-Match`, `If-Range`);
  *weak* = strip `W/`, compare opaque tag (`If-None-Match`). Comma-lists and `*` supported.
- **HTTP-date:** parse IMF-fixdate; tolerate obsolete RFC-850 and asctime forms.
  `last_modified == nil` ⇒ date conditions cannot fire (proceed).

### 4.3 `serve/2` orchestration

```
:other method ───────────────▶ 405 {allow: "GET, HEAD"}, :empty   (configurable via :methods)
GET/HEAD:
  Conditional.evaluate ─ :precondition_failed ─▶ 412 (validators, :empty)
                       ├ :not_modified ─────────▶ 304 (etag, last_modified, :empty)
                       └ :proceed:
        no Range ─────────────────────────────▶ 200 {:full, idx}
        Range + If-Range not satisfied ───────▶ 200 {:full, idx}        (entity changed)
        Range.parse ─ :ignore ─────────────────▶ 200 {:full, idx}
                     ├ :unsatisfiable ──────────▶ 416 (content-range: bytes */total, :empty)
                     ├ [single] ────────────────▶ 206 {:range, idx, off, len}
                     └ [many]  ─────────────────▶ 206 {:multipart, boundary, parts, idx}
  HEAD ⇒ identical status + headers, body coerced to :empty
```

### 4.4 Header matrix

Lowercased keys; user `:cache_control` / `:extra_headers` merged in. `accept-ranges: bytes`
is emitted on every 200/206 (required for Safari/iOS seeking).

| Status | Headers |
|--------|---------|
| 200 | `accept-ranges: bytes`, `etag`, `content-type`, `last-modified?`, `content-length: total` |
| 206 single | above + `content-range: bytes f-l/total`, `content-length: l-f+1` |
| 206 multipart | `accept-ranges`, `etag`, `last-modified?`, `content-type: multipart/byteranges; boundary=…`, `content-length: exact` |
| 304 | `etag`, `last-modified?`, `cache-control?` |
| 405 | `allow: GET, HEAD` |
| 412 | `etag`, `last-modified?` |
| 416 | `content-range: bytes */total`, `content-length: 0` |

### 4.5 `Response` bodies, multipart boundary, and exact `Content-Length`

- **Boundary** is derived **purely and deterministically** from the validator and the request
  shape: `boundary = "ISOMedia" <> Base.encode16(:erlang.md5(etag <> range_signature), case: :lower)`.
  `:erlang.md5/1` is a BIF (no `:crypto` application), so the core stays zero-dep; the boundary
  is observable from the `%Response{}` struct (good for tests) and cannot contain CRLF.
- **Per-part preamble** (built during `serve/2`, summed for the header *and* emitted by the stream):
  ```
  --BOUNDARY CRLF
  Content-Type: <media-content-type> CRLF
  Content-Range: bytes <first>-<last>/<total> CRLF
  CRLF
  ```
  followed by the `(last-first+1)` range bytes, then `CRLF`. Epilogue: `--BOUNDARY--CRLF`.
- **Exact multipart `Content-Length`** =
  `Σ (byte_size(preamble_i) + (last_i - first_i + 1) + 2) + byte_size(epilogue)`.
  Because the *same* preamble binaries are summed for the header and emitted by `body_stream`,
  **header == streamed bytes by construction** (locked by invariant #4). This lets H1 emit an
  exact length instead of falling back to chunked transfer, which keeps responses cacheable and
  friendly to picky reverse proxies.
- **`body_stream/2`** resolves each spec lazily over `SeekIndex.stream_range` (leak-safe, O(range)):
  - `{:full, _}` / `{:range, _, _, _}` → one `stream_range`.
  - `{:multipart, boundary, parts, idx}` → a `Stream` interleaving each part's preamble binary +
    its `stream_range` + `CRLF`, then the epilogue.
  - `:empty` → an empty stream (HEAD / 304 / 412 / 416).
- **`body_iodata/1`** is the materializing equivalent (small bodies, tests); invariant #5 asserts
  `body_stream |> Enum.into("") == body_iodata` for every spec.

### 4.6 `content_type/1` derivation

Ordered: top-level `styp` ⇒ `"video/iso.segment"` · brand `qt  ` ⇒ `"video/quicktime"` ·
HEIF brands (`heic`/`heix`/`mif1` + `pict` handler) ⇒ `"image/heic"`, `avif` ⇒ `"image/avif"` ·
any `vide` track ⇒ `"video/mp4"` · audio-only ⇒ `"audio/mp4"` · else `"application/mp4"`.
`opts[:content_type]` overrides entirely; `opts[:codecs]` appends `; codecs="…"` via
`ISOMedia.Manifest.codecs/1`.

### 4.7 `etag/2` strategy

- **`:pure`** (default) — fold `{path, offset, length}` per `{:slice, _}` segment and
  `:erlang.md5` of each `{:bytes, _}` segment, over the `SeekIndex` descriptors. No file I/O,
  O(#segments). A strong validator under the backing-files-immutable contract.
- **`:stat`** — additionally `File.stat` each *distinct* slice path and fold `mtime`+`size`
  (cheap metadata I/O, not payload). Detects a backing file rewritten underneath; emits a
  weak (`W/`) tag.

Named `etag` (not `byte_size`-style) and computed without walking payload bytes — the
O(range) memory story is preserved.

## 5. `ISOMedia.Plug` (optional reference adapter)

Compiled only when Plug is present:

```elixir
if Code.ensure_loaded?(Plug.Conn) do
  defmodule ISOMedia.Plug do
    @behaviour Plug
    # init opts:
    #   :resolver  (conn -> {:ok, tree | Resource.t()} | {:ok, tree, res_opts} | :not_found)
    #   :root      (dir; maps conn.request_path -> file, read lazy)  — alternative to :resolver
    #   :lazy      (read backing files as FileSlice; default true — the O(range) path)
    #   :cache     (:none | :persistent_term) — cache Resource by {path, mtime, size, opts}
    #   :chunk_size, :methods (default [:get, :head]), :etag (:pure | :stat),
    #   :cache_control, :extra_headers
  end
end
```

`call/2`: resolve → (build or cache-hit) `%Resource{}` → `from_headers(conn.req_headers,
conn.method)` → `serve/2` → merge headers + `put_status` → body. Body path:

- `:empty` (304 / 412 / 416 / 405 / HEAD) → `send_resp(conn, status, "")`.
- otherwise → `send_chunked/2`, then `body_stream/2 |> Enum.reduce_while(conn, &chunk/2)`.

**Disconnect contract:** a client that reads the `moov` and slams the socket (Safari/iOS do
this constantly) makes `Plug.Conn.chunk/2` return `{:error, :closed}`; we halt the reduce, and
`Stream.resource`'s `after_fun` inside `stream_range` closes any open fd — no descriptor leak,
no log blow-up.

**Caching** is where the O(range) economics land in production: caching the `Resource` (which
holds the already-built `SeekIndex` from a parsed tree) keyed by `{path, mtime, size}` lets
repeat range requests skip both the file parse and the index build.

Declared in `mix.exs` as `{:plug, "~> 1.0", optional: true}`; tests use `Plug.Test`
(test-only). The core remains zero-runtime-dependency.

## 6. Error-handling contract

- **Untrusted input never raises.** Every header parse (Range, HTTP-date, entity-tag, method)
  returns data; malformed ⇒ safe downgrade (`:ignore` → 200, or condition treated as absent).
  This is the public-boundary contract, mirroring `read_range/3`'s fail-fast-only-on-
  programmer-error stance.
- **Programmer misuse raises** `ArgumentError` (non-`Resource`/tree to `resource/2`, bad opts).
- **`serve/2` does zero payload I/O** ⇒ it cannot fail on disk. The only metadata I/O is
  `:stat`-mode `resource/2`; a missing backing file raises *at build time* with a clear
  message, never mid-stream.
- **Payload I/O errors surface only in `body_stream`**, as raises from
  `SeekIndex.stream_range` (short read / EOF / disk error) — identical to the existing
  streaming-write discipline.
- **No silent truncation.** Because `content-length` is computed to equal the streamed bytes,
  a short read raises rather than completing a truncated 200/206. This tears the connection
  down ungracefully on purpose, so a CDN/reverse proxy never caches a poisoned partial chunk.

## 7. Testing strategy

Oracle = the trusted `serialize/1`. `stream_data` (already a test dep) drives the properties.

| # | Invariant | Form |
|---|-----------|------|
| 1 | **Range fidelity** — 206 single body == `binary_part(serialize(tree), clamp(o,len))` | property (tree, offset, length) |
| 2 | **Full == serialize** — 200 body == `serialize(tree)` | property |
| 3 | **Multipart reassembly** — split body on boundary; each part's bytes == its `serialize` slice; parts cover exactly the coalesced request | property |
| 4 | **Content-Length exactness** — `content-length` header == Σ chunk sizes from `body_stream` (200, 206 single, 206 multipart) | property |
| 5 | **stream == iodata** — `body_stream \|> Enum.into("") == body_iodata` | property, every body spec |
| 6 | **Conditional precedence** — full RFC 7232 §6 matrix (presence × match × method) → exact status | table-driven |
| 7 | **ETag stability/sensitivity** — same tree ⇒ same tag; changed ⇒ different; `:stat` reacts to mtime, `:pure` does not | golden + property |
| 8 | **Range parser never raises** — arbitrary header strings → only `{:ok,_}\|:unsatisfiable\|:ignore`; satisfiable ranges ⊆ `[0,total)` | StreamData fuzz |
| 9 | **416** — fully-out-of-range ⇒ 416 + `content-range: bytes */total` | cases |
| 10 | **HEAD parity** — HEAD headers == GET headers, body empty | property |
| 11 | **End-to-end Plug** (if loaded) — `Plug.Test` conn → `call` → same oracles, incl. range/conditional/multipart | integration |
| 12 | **Content-Type golden** — mp4/mov/m4a/heic/segment corpus → expected type | golden |

## 8. Module/file plan

- `lib/iso_media/http.ex` — facade (`resource/2`, `serve/2`, `from_headers/2`, `etag/2`,
  `content_type/1`, `body_stream/2`, `body_iodata/1`) + `Resource`/`Request`/`Response` structs.
- `lib/iso_media/http/range.ex` — `ISOMedia.HTTP.Range`.
- `lib/iso_media/http/conditional.ex` — `ISOMedia.HTTP.Conditional`.
- `lib/iso_media/plug.ex` — optional `ISOMedia.Plug` (guarded by `Code.ensure_loaded?/1`).
- Re-exports on `lib/iso_media.ex` for facade parity.
- `mix.exs` — add `{:plug, "~> 1.0", optional: true}`; `Plug.Test` in the test environment.
- Tests under `test/iso_media/http/` mirroring §7.

## 9. Dependencies & invariants preserved

- **Zero runtime dependencies** in the core (`:erlang.md5` BIF for boundary/etag; `Base` and
  `:calendar` are Elixir/OTP stdlib). `:plug` is `optional: true` and never required at runtime.
- **Byte-for-byte round-trip** is the test oracle for every body path.
- **O(range) memory** holds for `FileSlice`-backed (lazy-read) trees end to end, including
  multipart, because bodies stream through `SeekIndex.stream_range`.
