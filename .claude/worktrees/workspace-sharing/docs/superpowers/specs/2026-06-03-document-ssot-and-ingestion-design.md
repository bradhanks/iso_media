# Document SSoT & Ingestion — Design (Step 1)

- **Date:** 2026-06-03
- **Status:** Approved (incorporates 2026-06-03 review — see §13 Revisions)
- **Scope:** Step 1 of the review lifecycle (`/demo/review`): **submit → convert → render**. The
  canonical single-source-of-truth (SSoT) document model and the ingestion pipeline that
  produces it. Steps 2 (agent review) and 3 (feedback generation) get their own specs.
- **Decision rule used throughout:** a well-reasoned, first-principles design is the null
  hypothesis; the existing codebase and any alternative must be ≥95% likely to be a better
  long-run solution to displace it. There are no users, so transition/backfill cost is not a
  factor — only long-run design quality.

---

## 1. Problem & goal

PerfectPaper ingests an author's manuscript, renders it professionally, and anchors AI
feedback to spans within it. Today the review surface (`DemoLive.Review`, `WorkspaceLive`)
renders a **faked** body: the left pane is just each comment's `original_text` printed as a
paragraph (`review_components.ex`), and feedback "highlighting" is whole-paragraph block
shading. There is no real document model: `Documents.Document` tracks an uploaded *file*
(filename, content_type, status, storage_key) but holds no rendered content, and
`Documents.Storage` conversion is an unwired stub.

We need one canonical representation that:

1. **Imports broadly** — `.docx`, legacy MS formats, ODT, HTML, LaTeX, Markdown, and the
   `.docx` exports of Google Docs / Microsoft 365.
2. **Renders professionally** — headings, sections, block quotes, lists, figures, tables,
   footnotes, references — as the left-hand reading pane.
3. **Anchors feedback precisely and durably** — every comment points at a specific span.
4. **Survives live co-editing in the long run** — multiple authors editing prose
   concurrently is a committed long-term requirement (it is the stated reason for the Phoenix
   refactor).

## 2. The locked architectural decision

**Canonical SSoT = our own editor-native, CRDT-ready AST. Pandoc (via Panpipe) is the import
*engine* that feeds it — not the canonical format itself.**

```
                  ┌─────────────────────────── Documents context ───────────────────────────┐
 upload (binary)  │  Storage.store     Importer (behaviour)        Canonical (changeset)      │
 docx/odt/html/…  │  ──────────────►   Pandoc AST ──► our AST ──►  validate ──►  persist JSONB │
                  │   storage_key       (Panpipe)    + stable ids                  status:✔   │
                  └──────────────────────────────────────────────────────────────────────────┘
                                                                          │ Events.emit(:converted)
                                                                          ▼
                                          render_tree/1 (web)  ──►  professional left pane
```

Why this clears the bar (summarized; full reasoning in the brainstorming transcript):

- **Co-editing disqualifies the simpler models.** Flat text + global character offsets, or
  whole-paragraph anchoring, *provably* shatter under concurrent edits: delete a word near the
  top and every downstream offset is wrong. A tree of typed nodes with **stable node IDs**
  anchors feedback to an immutable node, so anchors survive edits around them. This is the one
  model that satisfies requirement 4, so it dominates the alternatives.
- **Pandoc as canonical is a trap.** Pandoc's AST is built for one-shot conversion: no stable
  node identity, not designed for incremental sync, and it does not map cleanly to
  collaborative editing. Using it *only* as the ingestion engine keeps its enormous import
  breadth while letting our own AST own identity, rendering, anchoring, and future CRDT sync.
- **Editor-native (ProseMirror-shaped) AST aligns the future for free.** When we build live
  co-editing, a ProseMirror-shaped doc drops onto standard `y-prosemirror` / Yjs bindings with
  **zero schema migration**.

## 3. Scope

### In scope (Step 1)

- The canonical document model (the AST), its JSON shape, node set, and stable-ID scheme.
- A validation layer (changeset) for the canonical model.
- The ingestion pipeline: upload → store → convert (Panpipe/Pandoc) → transform → validate →
  persist, run as a background job with status transitions.
- The `Documents.Importer` behaviour + a `Pandoc` adapter.
- Professional rendering of the canonical AST in the review pane (replacing the faked body).
- The data-model *fields* for feedback anchoring (`node_id` + intra-node range) and rendering
  highlights from them.
- Linking a review `Session` to its source `Document` so a real manuscript renders.

### Out of scope (named, deferred to their own specs)

- **Live co-editing / Yjs–Yrs convergence engine** — model is built CRDT-ready; the sync
  runtime is not built. Transport (Channels/PubSub) and awareness (Presence) are also deferred.
- **PDF ingestion** — Pandoc cannot read PDF structure; this needs a separate extractor
  (layout tooling or an LLM pass). It slots in behind the same `Importer` behaviour later.
  *(Decision to confirm — see §10.)*
- **Agent / prompt engineering** — owned/org/owner prompts, the prompt-as-entity model.
- **Sub-agent fan-out** and any change to the existing one-shot `Chatbot.review/2`.
- **Generating** anchored feedback from the LLM (that is Step 2/3); Step 1 only lands the
  anchor schema and renders from it.
- **Real blob-storage adapter** — keep `Documents.Storage.Local`.

## 4. The canonical document model (SSoT)

ProseMirror-shaped JSON: a `doc` whose `content` is an ordered list of block nodes; block nodes
carry a **stable `id`**, optional `attrs`, and `content` (child blocks or inline content);
inline content is `text` nodes carrying `marks`.

```jsonc
{
  "type": "doc",
  "content": [
    {
      "type": "heading",
      "id": "n_8Kf3aZ",            // stable, minted once at ingestion
      "attrs": { "level": 1 },
      "content": [ { "type": "text", "text": "Rural–Urban Divides…" } ]
    },
    {
      "type": "paragraph",
      "id": "n_b21Qd0",
      "content": [
        { "type": "text", "text": "As shown in " },
        { "type": "text", "text": "Figure 2", "marks": [ { "type": "em" } ] },
        { "type": "text", "text": ", directed acyclic graphs…" }
      ]
    }
  ]
}
```

**Initial node set** (an academic-paper MVP; extend later via additional transform passes):

- Block: `doc`, `heading` (`attrs.level`), `paragraph`, `blockquote`, `bullet_list`,
  `ordered_list`, `list_item`, `code_block` (`attrs.language`), `figure` (`attrs.src`,
  caption child), `image`, `table` / `table_row` / `table_cell`, `footnote`,
  `horizontal_rule`.
- Inline: `text` with `marks` ∈ `strong`, `em`, `code`, `link` (`attrs.href`), `superscript`,
  `subscript`. Unknown Pandoc nodes degrade to `paragraph`/`text` rather than failing the
  whole document (logged).

**Stable IDs.** Every block node gets a unique `id` minted once at ingestion (short
URL-safe token, e.g. `"n_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)`).
IDs are persisted in the JSON and never regenerated; the future editor/CRDT preserves them
across edits. Inline `text` nodes are not individually IDed — they are addressed by offset
*within* their parent block (see §7).

**Elixir representation & validation.** The stored form is a JSONB map. The tree is **not**
modeled with Ecto `embedded_schema` / `cast_embed` — a recursive, polymorphic node tree (a
`blockquote` containing arbitrary blocks containing inlines) maps terribly onto nested embeds
and self-referential schemas. Instead, **`Documents.Canonical.validate_doc/1` does a manual
depth-first traversal** of the map, returning `{:ok, doc}` or `{:error, [%{path: [...],
error: ...}]}` (path = the JSON key route to the offending node). Per architecture law #4
("changeset on every write"), the persisting `Document` changeset casts the `:map` column and
runs `validate_doc/1` from a `validate_change`, so the DB never holds a malformed tree —
without forcing the tree itself into Ecto embeds.

**Extracted metadata.** Ingestion also pulls a small `canonical_meta` map — `title`,
`authors`, `abstract?`, `word_count`, `source_format` — from Pandoc's `meta` and a structural
pass. `title` seeds `Session.title`.

## 5. Data model & migrations

**(a) `documents`** — gains the converted representation; reuses the existing
`status` enum (`pending | converting | converted | failed`), which already models exactly this
pipeline.

| Column | Type | Notes |
|---|---|---|
| `canonical_doc` | `:map` (JSONB) | nullable until `:converted` |
| `canonical_meta` | `:map` (JSONB) | extracted title/authors/word_count/source_format |
| `source_format` | `:string` | detected input format (e.g. `"docx"`) |

**(b) `history_sessions`** — gains a link to its source document so a real manuscript renders.

| Column | Type | Notes |
|---|---|---|
| `document_id` | `:binary_id` | FK → `documents`, `on_delete: :nilify_all`, nullable |

The body is rendered from `Document.canonical_doc`; `Session` keeps `title` (seeded from
`canonical_meta`) and continues to own `overall_feedback` and comments.

**(c) `comments`** — gains anchor fields. `original_text` is retained as a *resolved snapshot*
(for display and as a fallback locator); `position` is retained for ordinal sort.

| Column | Type | Notes |
|---|---|---|
| `anchor_node_id` | `:string` | the stable block-node id the comment points at; nullable (general notes have no anchor) |
| `anchor_from` | `:integer` | start offset into the node's flattened text, in **UTF-16 code units** (§7) |
| `anchor_to` | `:integer` | end offset (exclusive), **UTF-16 code units** |

## 6. Ingestion pipeline

1. **`Documents.ingest(user, content, attrs)`** — stores the binary via `Storage.store/2`,
   registers the `Document` (`:pending`), and enqueues conversion. Returns `{:ok, document}`.
2. **`Documents.Conversion` (Oban worker, new queue `:documents`)** — sets `:converting`,
   reads the binary, selects an importer by format, and runs it.
3. **`Documents.Importer` (behaviour)** — `@callback import(binary(), keyword()) ::
   {:ok, canonical_map()} | {:error, term()}`. Default adapter **`Documents.Importer.Pandoc`**:
   - calls Pandoc through **Panpipe** (`Panpipe.ast!/2`) → `%Panpipe.AST.*` structs;
   - runs functional transform passes (`Panpipe.transform/2` + pattern matching) mapping Pandoc
     structs → our node maps;
   - **flattens inline marks:** Pandoc nests inlines (`Emph [Strong [Str "x"]]`); our model is
     flat `text` siblings carrying a `marks` array. The transform walks the inline tree
     **accumulating active marks downward**, emits a flat `text` node only at terminals
     (`Str`/`Space`/…), then **coalesces adjacent `text` nodes with identical marks** into one
     (`["Hello "(em), "World"(em)]` → `"Hello World"(em)`). Coalescing keeps the JSON small and
     keeps UTF-16 offset slicing simple.
   - mints stable IDs; extracts `canonical_meta`.
   - The importer returns **atom/JSON-keyed maps matching the schema** — vendor specifics
     (Pandoc/Panpipe shapes) do not leak past this adapter (architecture law #7).
4. **`Documents.Canonical.validate_doc/1`** validates the tree via manual recursive traversal
   (§4): recognized node types, required `attrs` per type, every block has an `id`, well-formed
   inline content.
5. **Persist** `canonical_doc` + `canonical_meta`, set `:converted`.
6. **`Events.emit(:document_converted, …)`** *after* the transaction commits (law: emit
   post-commit), fanning out to the LiveView and (later) webhooks.

   **Failure handling — classify by determinism.** **Deterministic** failures (validation
   failure, corrupt/unsupported file, Pandoc non-zero exit on bad input) set `:failed`, emit
   `:document_conversion_failed`, and return **`{:discard, reason}`** so Oban does **not** retry
   — retrying a deterministic error only burns CPU/DB. **Transient** failures (binary timeout,
   fs lock, OOM) return `{:error, _}` to use Oban's normal bounded retry + backoff.

**Operational note.** `Documents.Importer.Pandoc` shells out to a **Pandoc 3.x (≥ 3.6)** binary
(api-version 1.23, the version Panpipe 0.3.3 targets). Pin Pandoc in the build/deploy image.
Confirm Panpipe's command-runner dependency (e.g. Rambo) and the binaries it bundles when
wiring this — it affects the deploy image only, nothing architectural.

## 7. Feedback anchoring

A comment locates its target as **`anchor_node_id` + `[anchor_from, anchor_to)`**, where the
offsets index into the *flattened text* of that block node (the concatenation of its `text`
children).

**Offset units are UTF-16 code units — not Elixir graphemes or codepoints.** Chosen
deliberately: ProseMirror and Yjs (`Y.Text`) both index text by JavaScript string semantics
(UTF-16 code units), so storing anchors in that unit means our DB coordinates map onto the
future editor/CRDT layer with **zero translation**. Elixir's `String.length/1` counts
*graphemes* and would silently disagree on any character outside the BMP (`"📊"` is 1 grapheme /
1 codepoint but **2** UTF-16 units), drifting every downstream highlight. The importer computes
offsets in UTF-16 (e.g. `:unicode.characters_to_binary(text, :utf8, {:utf16, :little})`, then
counting 16-bit units), and `DocumentComponents` slices in the same unit. Properties:

- **Durable under edits.** Because the coordinate space is scoped to a single node, edits
  elsewhere never move the anchor. Edits *within* the node may shift offsets — the future Yjs
  layer maintains intra-node positions via relative positions; until then, `original_text`
  serves as a re-locate fallback.
- **Word-precise highlight.** Rendering can wrap exactly `[from, to)` in a highlight span,
  versus today's whole-paragraph shading.
- **General notes** (no passage) carry `anchor_node_id = nil` and render in the feedback list
  without a document highlight, as today.

Step 1 lands these fields and renders highlights from them; *populating* them from the LLM is
Step 2/3.

## 8. Rendering

A new web component, `DocumentComponents.render_tree/1`, walks `canonical_doc` and emits HEEx:
each node type maps to a semantic element styled with the `paper` daisyUI theme + the
`font-serif`/`font-display` type scale (per `CLAUDE.md` / `BRAND.md`). It replaces the faked
body in `review_panes`. Requirements:

- **HTML-escape all text** from the document (untrusted author content) — no raw interpolation.
- Highlights are rendered by walking inline content and splitting `text` at the active
  comment's `[from, to)`; discrete, test-stable ids per node (`id={"node-#{node_id}"}`), no
  multi-match selectors.
- `WorkspaceLive` renders from the linked `Document.canonical_doc`; `DemoLive.Review` renders
  from a static canonical fixture (so the demo and the real surface render the same component).

**Large-document handling — acknowledged, deferred.** A very large `canonical_doc` held in
LiveView assigns has the same memory/diff concern as raw binary in assigns. Step 1 holds the
whole tree in assigns (correct for the demo's manuscript-sized inputs). Streaming / windowed
rendering (e.g. LiveView streams over top-level blocks, lazy node loading) is a deferred
optimization, not a Step 1 decision — but the node-keyed render (`id={"node-#{node_id}"}`) is
designed so it can be retrofitted without reshaping the model.

## 9. Public API (Documents context)

- `ingest(user, content, attrs) :: {:ok, Document.t()} | {:error, …}`
- `get_document(id, scope) :: Document.t() | nil`
- `canonical_doc(document) :: map() | nil`
- `read_content/1`, `register_upload/2`, `mark_converted/2` — retained.
- Internal: `Documents.Conversion` (Oban), `Documents.Importer` (+ `Pandoc`),
  `Documents.Canonical` (validation). All IO and the only public surface stay in
  `Documents`; other contexts/web call `PerfectPaper.Documents.*` only (law #1).

## 10. Decisions to confirm at review

> **All four confirmed in the 2026-06-03 review.** Retained for traceability.

1. **PDF deferred** to its own `Importer` adapter; Step 1 ships the Pandoc-served formats plus
   the adapter boundary so PDF slots in later. *(Highest-impact call — PDF was emphasized as a
   target. The reason to defer: PDF→structured-AST is a fundamentally different, hard problem
   that would balloon Step 1.)*
2. **Single JSONB blob** for `canonical_doc`, not normalized node rows. (Rows fight the tree
   model, complicate ordering/sync, and don't match how editors/Yjs serialize.)
3. **`Session.document_id` link**; body rendered from `Document.canonical_doc` rather than
   storing body on `Session`.
4. **Conversion as an Oban job** on a new `:documents` queue (async, status-driven), using the
   existing `status` enum.

## 11. Testing strategy

- **Importer transform** (`Documents.Importer.Pandoc`): fixture inputs (Markdown, a small
  `.docx`, HTML) → expected canonical maps; every block has a stable id; unknown nodes degrade.
- **Canonical validation** (`Documents.Canonical`): rejects missing ids, unknown node types,
  malformed inline content; accepts the golden tree.
- **Pipeline** (`Documents`): `ingest` enqueues; the worker drives `pending → converting →
  converted`; a failing import lands `:failed` after one retry; `:document_converted` emitted
  post-commit.
- **Rendering** (`DocumentComponents`): a canonical fixture renders expected structure with
  correct escaping; a comment anchor highlights exactly `[from, to)` on the right node.
- Scope tests to this task; reserve the full suite / `mix precommit` for the pre-merge check.

## 12. Deferred backlog (explicit)

Yjs/Yrs convergence engine and Channels/Presence co-editing wiring · PDF importer · Agent /
prompt-as-entity model and owner/org prompts · sub-agent fan-out · LLM-populated anchors ·
real blob-storage adapter · multi-document/appendix composition beyond the existing
`parent_document_id` · large-document streaming/windowed rendering · **document export**
(our AST → Pandoc AST → docx/PDF/Markdown — the `WorkspaceLive` Download menu is currently
unwired; the same Panpipe engine powers it in reverse, but it is out of Step 1 scope).

## 13. Revisions

- **2026-06-03 — review 1.** Incorporated targeted review:
  - **(A)** Anchor offsets specified in **UTF-16 code units** to map zero-translation onto
    ProseMirror/Yjs and avoid silent BMP-character drift (§5, §7).
  - **(B)** Canonical validation is a **schemaless recursive `validate_doc/1`** (manual DFS),
    *not* Ecto `embedded_schema`/`cast_embed`; wrapped by the `Document` changeset via
    `validate_change` (§4, §6).
  - **(C)** Importer transform must **accumulate inline marks downward and coalesce adjacent
    same-mark `text` nodes** (§6).
  - **(D)** Oban conversion failures **classified transient vs deterministic**; deterministic →
    `{:discard, reason}` (no retry) (§6).
  - All four §10 decisions **confirmed**.
- **Panpipe: depend, don't fork — CONFIRMED.** Dependency is `{:panpipe, "~> 0.3"}` (hex).
  Hard-forking was proposed and rejected: the `Documents.Canonical`/import transform is a strict
  translation barrier, so the app already has 100% insulation — a fork buys **no additional
  insulation** while taking on a guaranteed liability (maintaining ~1,500 LOC of Pandoc→Elixir
  AST mapping, chasing Elixir compile warnings and `pandoc-api-version` bumps). MIT license keeps
  the fork/vendor escape hatch open (≈1 hour) if Panpipe is ever abandoned or we must edit its
  internals — so we don't pre-pay for it now.
