# panpipe ⇄ perfect_paper: Canonical Import Boundary — Design

**Date:** 2026-06-04
**Status:** Approved (design); ready for implementation planning
**Repos:** `panpipe` (library) and `perfect_paper` (app) — cross-repo change

## Summary

`perfect_paper` currently has its **own** canonical-AST engine
(`PerfectPaper.Documents.Canonical` + `Documents.Importer.Pandoc`) that duplicates
the richer engine built in the **panpipe** fork (`Canonical.*`). This spec
consolidates: **panpipe becomes the single, authoritative document-model + import
library**, and `perfect_paper` depends on it (via git) and deletes its duplicate.

The boundary: panpipe owns *what a canonical document is and how to produce one
from a source file*; perfect_paper owns *persistence, jobs, storage, web, LLM*.
Only plain JSON maps cross the boundary (panpipe's structs stay internal), so
perfect_paper keeps storing JSONB and validating maps.

## Key decisions (locked)

| # | Decision |
|---|----------|
| 1 | **Consolidate** onto panpipe; perfect_paper deletes its duplicate engine and consumes panpipe. |
| 2 | **Authoritative node shape = panpipe's**: node id lives in **`attrs["id"]`** (ProseMirror-correct; future-editor-friendly). perfect_paper's renderer + anchoring adapt to read `attrs["id"]`. |
| 3 | **Dependency = git**: `{:panpipe, git: "https://github.com/bradhanks/panpipe.git", tag: <tag>}`. Requires pushing the fork (`master` is 21 commits ahead of `origin`) and tagging. |
| 4 | **Boundary is map-based**: panpipe exposes plain-map APIs; structs stay internal to panpipe. |
| 5 | Demo wiring (upload→convert→display gaps) is **out of scope** — separate follow-on (see `2026-06-04-docx-upload-wiring-design.md`). |

## Architecture / the boundary

### panpipe owns (pure library — no Phoenix/Ecto/Oban)

Existing internal modules unchanged: `Canonical.{Node,Mark}`, `Canonical.Schema`,
`Canonical.Schema.{ContentExpr,Pandoc,Validator}`, `Canonical.Import.{Block,Inline,Attrs}`,
`Canonical.Id`, `Canonical.PM`.

**New: UTF-16 text/anchor helpers** (moved in from perfect_paper's `Documents.Canonical`).
A `Canonical.Text` module (or additions to an existing module):

```elixir
@spec flatten_text(map()) :: String.t()          # concatenate a node's descendant text
@spec utf16_length(String.t()) :: non_neg_integer()
@spec utf16_slice(String.t(), from :: non_neg_integer(), to :: non_neg_integer()) :: String.t()
```

Note the input types per the review watch-out: `flatten_text/1` takes a **node map**
and returns a **string**; `utf16_length/1` and `utf16_slice/3` operate on the
**flattened string**, not the map. (Elixir is UTF-8 internally; these compute
UTF-16 code-unit offsets for the JS/ProseMirror frontend, which addresses text in
UTF-16.) Unit-tested in panpipe, including a multi-byte/emoji/surrogate-pair case.

**`utf16_slice/3` uses `(string, from, to)` END-OFFSET semantics — NOT
`(from, length)`** — because perfect_paper's existing callers slice as
`utf16_slice(full, 0, from)`, `utf16_slice(full, from, to)`, `utf16_slice(full, to, len)`.
Implementation: convert UTF-8 → UTF-16 binary via
`:unicode.characters_to_binary(s, :utf8, {:utf16, :little})`, `binary_part/3` on
byte bounds `from*2 .. to*2` (clamped to the binary length), then convert back to
UTF-8 with the **same `{:utf16, :little}`** endianness. Native binary work; handles
surrogate pairs (emoji) correctly; preserves existing call sites unchanged.

**New: map-based boundary API** (on the `Canonical` façade):

```elixir
# Run pandoc -> canonical -> mint ids -> validate; return PM JSON map + metadata.
@spec import_document(binary() | keyword(), keyword()) ::
        {:ok, %{doc: map(), meta: map(), warnings: [term()]}} | {:error, term()}

# Validate a plain PM JSON map (internally: PM.from_json |> Validator.validate).
@spec validate(map()) :: :ok | {:error, [map()]}
```

`import_document/2` internally calls the existing `ingest/2`, then `PM.to_json/1`,
and builds `meta`:

```elixir
%{
  "title"         => first heading's flattened text | nil,
  "word_count"    => word count of the whole flattened doc,
  "source_format" => opts[:source_format] || detected format string
}
```

(The existing struct-returning `Canonical.ingest/2` stays for internal/other use;
`import_document/2` is the map-based boundary perfect_paper consumes.)

### perfect_paper owns (the app — consumes panpipe)

- **Deletes** `PerfectPaper.Documents.Importer.Pandoc` and `PerfectPaper.Documents.Canonical`.
- **Keeps** the `Documents.Importer` behaviour and `Documents.Importer.Stub` (hermetic tests).
- **New** `Documents.Importer.Panpipe` — a thin adapter implementing the behaviour by
  delegating to `Canonical.import_document/2` (returns `{:ok, %{doc, meta}}`).
- Repoints call sites that used the deleted modules:
  - `Documents.Conversion` (Oban worker) — validation via `Canonical.validate/1`.
  - `Documents.Document.canonical_changeset/2` — validation via `Canonical.validate/1`.
  - `Documents.highlight_segments/2` — `Canonical.flatten_text/utf16_length/utf16_slice`.
- **Adapts renderer + anchoring to `attrs["id"]`:**
  - `DocumentComponents.render_tree` — block id becomes `node["attrs"]["id"]`
    (`id={"node-#{...}"}`).
  - `Documents.highlight_segments/2` — anchor match keys off `get_in(node, ["attrs","id"])`
    instead of top-level `node["id"]`.

### The data contract (only thing crossing the boundary)

Canonical doc map:
```
%{"type" => string,
  "attrs" => %{"id" => string, ...},   # id on block/atomic nodes; absent on "text"
  "content" => [child maps],
  "marks" => [%{"type" => string, "attrs" => map}],
  "text" => string}                    # only on "text" nodes
```
`meta`: `%{"title" => string | nil, "word_count" => integer, "source_format" => string}`.

## Renderer fallback safety (review watch-out #1)

panpipe emits richer block node types than perfect_paper's renderer currently
handles (`table`, `table_row`, `table_cell`, `bullet_list`/`ordered_list`/`list_item`
[handled], `image`, `math`, `footnote`, `definition_list`, `div`, `blockquote`
[handled]). The current renderer falls back **unknown → paragraph**, which is unsafe:
a `paragraph` is an *inline* container, so rendering a block node's block children
inside it garbles or crashes the renderer.

**Fix:** change the fallback for unrecognized nodes:
- **Block-ish nodes** (have a `content` list of block children) → render as a generic
  block container (`<div data-node-type={type}>`) that **recurses children as blocks**.
- **Inline/text** → render as text.

This guarantees no block content is forced into an inline container. Extending the
renderer with first-class `table`/`image` styling is a **separate follow-on** (the
generic-block fallback keeps them correct-but-plain meanwhile).

## Migration mechanics

1. **panpipe**: add `Canonical.Text` (UTF-16 helpers), `Canonical.import_document/2`,
   `Canonical.validate/1` (map). Add unit tests. Format, full suite green.
2. **panpipe**: tag (e.g. `v0.4.0-canonical`); **push `master` + tag to `origin`**
   (`github.com/bradhanks/panpipe`). *(Outward-facing — confirm before pushing.)*
3. **perfect_paper** `mix.exs`: replace `{:panpipe, "~> 0.3"}` with
   `{:panpipe, git: "https://github.com/bradhanks/panpipe.git", tag: "<tag>"}`;
   `mix deps.get`.
4. **perfect_paper**: add `Importer.Panpipe`; switch the configured importer to it;
   delete `Importer.Pandoc` + `Documents.Canonical`; repoint call sites; adapt
   renderer + `highlight_segments` to `attrs["id"]`.
5. **perfect_paper**: run the suite; fix fallout.

## Testing

- **panpipe:** `import_document/2` returns map + correct `meta` (title/word_count/source_format);
  `validate/1` accepts a map and rejects a malformed one; UTF-16 helpers (incl. an emoji /
  surrogate-pair case) — `flatten_text` on a node map, `utf16_length`/`utf16_slice` on strings.
- **perfect_paper:** `Importer.Panpipe` adapter returns `{:ok, %{doc, meta}}` for a docx
  fixture (or uses `Stub` for hermetic context tests); `DocumentComponents` renders a doc
  whose ids are in `attrs["id"]` and a generic-block fallback for an unknown block type
  (asserts children render as blocks, not nested in a `<p>`); `highlight_segments` matches
  on `attrs["id"]`; `Conversion` worker test stays green.

## Scope exclusions & known consequences

- **Out of scope:** docx demo wiring (`store_and_register`→`ingest`, session↔document link,
  WorkspaceLive live refresh). Covered by `2026-06-04-docx-upload-wiring-design.md`.
- **Out of scope:** first-class table/image rendering (generic-block fallback covers
  correctness for now).
- **Rollback:** dependency swap + module deletions on a branch in each repo; revert
  restores the in-repo engine and `~> 0.3` dep.

## Resolved (review)

- **panpipe tag:** `v0.4.0-canonical`. (Clean `v0.4.0` after the integration validates.)
- **Importer indirection:** keep it. `config :perfect_paper, :document_importer` →
  `Importer.Stub` in `test.exs`, `Importer.Panpipe` in `dev.exs`/`prod.exs`. Keeps the
  business-logic test suite from shelling out to pandoc.
- **Base branch:** `feat/panpipe-canonical-boundary` off `main` (done).
- **`utf16_slice/3`:** `(string, from, to)` end-offset API (see UTF-16 section) — do **not**
  switch to `(from, length)`.

## CI / deploy prerequisite (git dependency)

The git dep uses an `https` URL. Whatever builds the app (CI, Docker, fly.io, etc.) must
be able to fetch `github.com/bradhanks/panpipe`. If the fork is **private**, switch the
dep to SSH (`git@github.com:bradhanks/panpipe.git`) and ensure deploy/CI SSH keys (or a
read token) are present. Verify the fork's visibility during the plan; pin to the
`v0.4.0-canonical` **tag** (not a moving branch) for reproducible builds.
