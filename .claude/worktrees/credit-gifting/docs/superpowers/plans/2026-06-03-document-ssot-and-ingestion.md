# Document SSoT & Ingestion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ingest an uploaded manuscript, convert it (via Pandoc/Panpipe) into a canonical, editor-native, CRDT-ready AST persisted as JSONB, and render it professionally in the review pane — with feedback-anchor columns (UTF-16) in place for later steps.

**Architecture:** `Documents` context owns ingestion and the SSoT. Upload → `Storage.store` → Oban `Documents.Conversion` worker → `Documents.Importer` (Panpipe → our AST, marks flattened + coalesced, stable IDs minted) → `Documents.Canonical.validate_doc/1` (schemaless recursive validation, **not** Ecto embeds) → persist JSONB → `Events.emit` post-commit. The web `DocumentComponents.render_tree/1` walks the AST. Anchors are stored as `node_id` + UTF-16 `[from, to)`.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto (binary_id, JSONB `:map`), Oban 2.23, Panpipe `~> 0.3` + a system Pandoc 3.x binary, Phoenix.Component/HEEx.

**Spec:** `docs/superpowers/specs/2026-06-03-document-ssot-and-ingestion-design.md`. PDF ingestion and live co-editing are **out of scope**.

**Branch:** All work lands on `feat/doc-ssot-ingestion`, cut from `main`.

---

## File Structure

**New files**
- `lib/perfect_paper/documents/canonical.ex` — pure SSoT validator + UTF-16/flatten helpers.
- `lib/perfect_paper/documents/importer.ex` — `@behaviour` for ingestion engines.
- `lib/perfect_paper/documents/importer/pandoc.ex` — Panpipe-backed adapter (default).
- `lib/perfect_paper/documents/importer/stub.ex` — deterministic adapter for hermetic tests.
- `lib/perfect_paper/documents/conversion.ex` — Oban worker.
- `lib/perfect_paper_web/components/document_components.ex` — `render_tree/1`.
- `priv/repo/migrations/<ts>_add_canonical_to_documents.exs`
- `priv/repo/migrations/<ts>_add_document_to_sessions.exs`
- `priv/repo/migrations/<ts>_add_anchors_to_comments.exs`
- `test/perfect_paper/documents/canonical_test.exs`
- `test/perfect_paper/documents/importer/pandoc_test.exs`
- `test/perfect_paper/documents/conversion_test.exs`
- `test/perfect_paper_web/components/document_components_test.exs`

**Modified files**
- `mix.exs` — add `{:panpipe, "~> 0.3"}`.
- `config/config.exs` — Oban `:documents` queue + `:document_importer` provider.
- `config/test.exs` — point `:document_importer` at the Stub.
- `lib/perfect_paper/events/event.ex` — extend `@types`.
- `lib/perfect_paper/documents/document.ex` — fields + `canonical_changeset/2`, `status_changeset/2`, `source_format` in `register_changeset`.
- `lib/perfect_paper/documents.ex` — `ingest/3`, `get_document/1`, `canonical_doc/1`, `highlight_segments/2`, `importer/0`.
- `lib/perfect_paper/history/session.ex` — `document_id` field + cast.
- `lib/perfect_paper/history/comment.ex` — anchor fields + cast.
- `lib/perfect_paper_web/live/workspace_live.ex` — render the linked document.
- `test/perfect_paper/documents_test.exs` — `ingest/3` tests.
- `test/test_helper.exs` — exclude `:pandoc`-tagged tests by default.

---

## Task 0: Branch

- [ ] **Step 1: Cut a clean branch off main**

The current branch (`feat/entra-sso`) has unrelated uncommitted work. Do **not** carry it over.

```bash
git stash push -u -m "park before doc-ssot" 2>/dev/null || true
git checkout main
git pull --ff-only 2>/dev/null || true
git checkout -b feat/doc-ssot-ingestion
```

Expected: now on `feat/doc-ssot-ingestion`, working tree clean. (The specs/stubs from brainstorming are untracked and will be added in Task 1's commit.)

- [ ] **Step 2: Confirm Pandoc is installed**

Run: `pandoc --version`
Expected: `pandoc 3.x` (≥ 3.6). If missing: `brew install pandoc`. Record the version in the commit message.

---

## Task 1: Dependencies, Oban queue, importer provider, event types

**Files:**
- Modify: `mix.exs:74`
- Modify: `config/config.exs` (Oban block ~108–113; adapter block ~27–32)
- Modify: `config/test.exs`
- Modify: `lib/perfect_paper/events/event.ex:6`

- [ ] **Step 1: Add Panpipe to deps**

In `mix.exs`, add to the `deps/0` list:

```elixir
      {:oban, "~> 2.23"},
      {:panpipe, "~> 0.3"}
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: `panpipe` and its transitive deps resolve and compile.

- [ ] **Step 3: Add the `:documents` Oban queue**

In `config/config.exs`, change the Oban queues line:

```elixir
config :perfect_paper, Oban,
  repo: PerfectPaper.Repo,
  queues: [webhooks: 10, documents: 10],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]
```

- [ ] **Step 4: Register the importer provider (default = Pandoc)**

In `config/config.exs`, alongside the other provider lines:

```elixir
config :perfect_paper, :storage_provider, PerfectPaper.Documents.Storage.Local
config :perfect_paper, :document_importer, PerfectPaper.Documents.Importer.Pandoc
```

In `config/test.exs`, override to the Stub so context/worker tests are hermetic (no Pandoc binary dependency):

```elixir
config :perfect_paper, :document_importer, PerfectPaper.Documents.Importer.Stub
```

- [ ] **Step 5: Extend the event-type whitelist**

`Events.Event` validates `type` against a closed enum — without this, `emit(:"document.converted", …)` returns `{:error, changeset}`. In `lib/perfect_paper/events/event.ex`, extend `@types`:

```elixir
  @types ~w(session.completed comment.added comment.addressed comment.dismissed session.shared subscription.updated credits.low document.converted document.conversion_failed)a
```

- [ ] **Step 6: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 7: Commit**

```bash
git add mix.exs mix.lock config/config.exs config/test.exs lib/perfect_paper/events/event.ex docs/superpowers/specs docs/superpowers/plans
git commit -m "chore(documents): add panpipe dep, :documents oban queue, importer provider, document event types

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `Documents.Canonical` — validator + UTF-16 helpers (pure)

**Files:**
- Create: `lib/perfect_paper/documents/canonical.ex`
- Test: `test/perfect_paper/documents/canonical_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule PerfectPaper.Documents.CanonicalTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Documents.Canonical

  @valid %{
    "type" => "doc",
    "content" => [
      %{"type" => "heading", "id" => "n_a", "attrs" => %{"level" => 1},
        "content" => [%{"type" => "text", "text" => "Title"}]},
      %{"type" => "paragraph", "id" => "n_b",
        "content" => [
          %{"type" => "text", "text" => "Plain "},
          %{"type" => "text", "text" => "bold", "marks" => [%{"type" => "strong"}]}
        ]}
    ]
  }

  describe "validate_doc/1" do
    test "accepts a well-formed tree" do
      assert {:ok, @valid} == Canonical.validate_doc(@valid)
    end

    test "rejects a block node missing a stable id" do
      bad = put_in(@valid, ["content", Access.at(0)], %{"type" => "heading", "content" => []})
      assert {:error, errors} = Canonical.validate_doc(bad)
      assert Enum.any?(errors, &(&1.error =~ "missing stable :id"))
    end

    test "rejects an unknown node type" do
      bad = put_in(@valid, ["content", Access.at(1), "type"], "spaceship")
      assert {:error, errors} = Canonical.validate_doc(bad)
      assert Enum.any?(errors, &(&1.error =~ "unknown node type"))
    end

    test "rejects a non-doc root" do
      assert {:error, _} = Canonical.validate_doc(%{"type" => "paragraph"})
    end
  end

  describe "UTF-16 helpers" do
    test "utf16_length counts code units, not graphemes" do
      assert Canonical.utf16_length("ab") == 2
      # 📊 is one grapheme/codepoint but TWO UTF-16 code units
      assert Canonical.utf16_length("a📊") == 3
    end

    test "utf16_slice cuts on code-unit boundaries" do
      assert Canonical.utf16_slice("hello world", 0, 5) == "hello"
      assert Canonical.utf16_slice("a📊b", 0, 1) == "a"
      assert Canonical.utf16_slice("a📊b", 3, 4) == "b"
    end

    test "flatten_text concatenates inline text in order" do
      node = Enum.at(@valid["content"], 1)
      assert Canonical.flatten_text(node) == "Plain bold"
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/perfect_paper/documents/canonical_test.exs`
Expected: FAIL — `Canonical` is undefined.

- [ ] **Step 3: Implement the module**

```elixir
defmodule PerfectPaper.Documents.Canonical do
  @moduledoc """
  The canonical document SSoT: a ProseMirror-shaped tree of typed nodes with
  stable block IDs. This module is PURE — it validates a tree map and provides
  the UTF-16 offset/flatten helpers anchors and rendering depend on.

  Validation is a manual recursive traversal (NOT Ecto `cast_embed`): a recursive,
  polymorphic node tree maps terribly onto nested embeds.

  Offsets are UTF-16 code units so DB coordinates map zero-translation onto the
  future ProseMirror/Yjs layer.
  """

  @block_types ~w(doc heading paragraph blockquote bullet_list ordered_list list_item code_block figure image table table_row table_cell footnote horizontal_rule)
  @inline_marks ~w(strong em code link superscript subscript)

  @type error :: %{path: [term()], error: String.t()}

  @doc "Validates a canonical doc map. Returns the doc or a list of path-tagged errors."
  @spec validate_doc(map()) :: {:ok, map()} | {:error, [error()]}
  def validate_doc(%{"type" => "doc", "content" => content} = doc) when is_list(content) do
    case validate_nodes(content, ["content"]) do
      [] -> {:ok, doc}
      errors -> {:error, errors}
    end
  end

  def validate_doc(_),
    do: {:error, [%{path: [], error: "root must be a doc node with a content list"}]}

  defp validate_nodes(nodes, path) do
    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, i} -> validate_node(node, path ++ [i]) end)
  end

  defp validate_node(%{"type" => "text", "text" => t} = node, path) when is_binary(t),
    do: validate_marks(Map.get(node, "marks", []), path)

  defp validate_node(%{"type" => "text"}, path),
    do: [%{path: path, error: "text node requires a string :text"}]

  defp validate_node(%{"type" => type, "id" => id} = node, path)
       when is_binary(id) and is_binary(type) do
    if type in @block_types,
      do: validate_children(node, path),
      else: [%{path: path, error: "unknown node type #{inspect(type)}"}]
  end

  defp validate_node(%{"type" => type}, path) when is_binary(type),
    do: [%{path: path, error: "block node #{inspect(type)} missing stable :id"}]

  defp validate_node(_, path), do: [%{path: path, error: "node missing :type"}]

  defp validate_children(%{"content" => content}, path) when is_list(content),
    do: validate_nodes(content, path ++ ["content"])

  # Leaf blocks (horizontal_rule, image) legitimately have no content.
  defp validate_children(_, _), do: []

  defp validate_marks(marks, path) when is_list(marks) do
    Enum.flat_map(marks, fn
      %{"type" => m} when m in @inline_marks -> []
      other -> [%{path: path, error: "unknown mark #{inspect(other)}"}]
    end)
  end

  defp validate_marks(_, path), do: [%{path: path, error: "marks must be a list"}]

  @doc "Concatenates all descendant inline text of a node, in document order."
  @spec flatten_text(map()) :: String.t()
  def flatten_text(node), do: node |> node_text() |> IO.iodata_to_binary()

  defp node_text(%{"type" => "text", "text" => t}), do: t
  defp node_text(%{"content" => content}) when is_list(content), do: Enum.map(content, &node_text/1)
  defp node_text(_), do: []

  @doc "Length of a string in UTF-16 code units."
  @spec utf16_length(String.t()) :: non_neg_integer()
  def utf16_length(string) do
    div(byte_size(:unicode.characters_to_binary(string, :utf8, {:utf16, :little})), 2)
  end

  @doc "Slices `[from, to)` of a string measured in UTF-16 code units."
  @spec utf16_slice(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def utf16_slice(string, from, to) when to >= from do
    u16 = :unicode.characters_to_binary(string, :utf8, {:utf16, :little})
    len = byte_size(u16)
    a = min(from * 2, len)
    b = min(to * 2, len)

    case :unicode.characters_to_binary(binary_part(u16, a, max(b - a, 0)), {:utf16, :little}, :utf8) do
      bin when is_binary(bin) -> bin
      _ -> ""
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/perfect_paper/documents/canonical_test.exs`
Expected: PASS (all assertions).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/documents/canonical.ex test/perfect_paper/documents/canonical_test.exs
git commit -m "feat(documents): Canonical SSoT validator + UTF-16 offset helpers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Migration + Document schema — canonical columns

**Files:**
- Create: `priv/repo/migrations/<ts>_add_canonical_to_documents.exs`
- Modify: `lib/perfect_paper/documents/document.ex`
- Test: `test/perfect_paper/documents_test.exs` (append)

- [ ] **Step 1: Generate the migration file**

Run: `mix ecto.gen.migration add_canonical_to_documents`
Expected: prints the created path under `priv/repo/migrations/`. Open it and replace the body with:

```elixir
defmodule PerfectPaper.Repo.Migrations.AddCanonicalToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :canonical_doc, :map
      add :canonical_meta, :map
      add :source_format, :string
    end
  end
end
```

- [ ] **Step 2: Migrate**

Run: `mix ecto.migrate`
Expected: `add_canonical_to_documents` runs without error.

- [ ] **Step 3: Write the failing test**

Append to `test/perfect_paper/documents_test.exs`:

```elixir
  describe "canonical_changeset/2" do
    test "accepts a valid canonical doc and sets :converted" do
      user = user_fixture()
      doc = document_fixture(user)

      tree = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "id" => "n_1", "content" => [%{"type" => "text", "text" => "Hi"}]}
        ]
      }

      changeset =
        PerfectPaper.Documents.Document.canonical_changeset(doc, %{
          canonical_doc: tree,
          canonical_meta: %{"title" => "T"},
          source_format: "markdown",
          status: :converted
        })

      assert changeset.valid?
      assert {:ok, saved} = PerfectPaper.Repo.update(changeset)
      assert saved.status == :converted
      assert saved.canonical_doc["content"] |> hd() |> Map.get("id") == "n_1"
    end

    test "rejects a malformed canonical doc" do
      user = user_fixture()
      doc = document_fixture(user)

      bad = %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => []}]}

      changeset =
        PerfectPaper.Documents.Document.canonical_changeset(doc, %{canonical_doc: bad, status: :converted})

      refute changeset.valid?
      assert %{canonical_doc: [msg]} = errors_on(changeset)
      assert msg =~ "missing stable :id"
    end
  end
```

- [ ] **Step 4: Run to verify it fails**

Run: `mix test test/perfect_paper/documents_test.exs`
Expected: FAIL — `canonical_changeset/2` undefined.

- [ ] **Step 5: Add fields + changesets to the schema**

In `lib/perfect_paper/documents/document.ex`, add fields inside `schema "documents" do` (after `:storage_key`):

```elixir
    field :canonical_doc, :map
    field :canonical_meta, :map
    field :source_format, :string
```

Add `:source_format` to the `register_changeset/2` cast list. Then add these functions after `convert_changeset/2`:

```elixir
  @doc "Persists the converted canonical AST; validates it via Documents.Canonical."
  @spec canonical_changeset(t(), map()) :: Ecto.Changeset.t()
  def canonical_changeset(document, attrs) do
    document
    |> cast(attrs, [:canonical_doc, :canonical_meta, :source_format, :status])
    |> validate_change(:canonical_doc, fn :canonical_doc, doc ->
      case PerfectPaper.Documents.Canonical.validate_doc(doc) do
        {:ok, _} ->
          []

        {:error, errors} ->
          first = hd(errors)
          path = Enum.join(first.path, " -> ")
          [canonical_doc: "[at #{path}] #{first.error}"]
      end
    end)
  end

  @doc "Sets only the processing status (used by the conversion worker)."
  @spec status_changeset(t(), atom()) :: Ecto.Changeset.t()
  def status_changeset(document, status), do: change(document, status: status)
```

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/perfect_paper/documents_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/perfect_paper/documents/document.ex test/perfect_paper/documents_test.exs
git commit -m "feat(documents): canonical_doc/meta columns + canonical_changeset

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `Documents.Importer` behaviour + `Stub` adapter

**Files:**
- Create: `lib/perfect_paper/documents/importer.ex`
- Create: `lib/perfect_paper/documents/importer/stub.ex`

- [ ] **Step 1: Write the behaviour**

```elixir
defmodule PerfectPaper.Documents.Importer do
  @moduledoc """
  Anti-corruption boundary for document ingestion. An importer turns a raw
  uploaded binary into our canonical SSoT — `%{doc: canonical_map, meta: map}`.
  No third-party AST shapes (Pandoc/Panpipe) leak past an implementation.
  """

  @doc "Imports raw `content` into a canonical doc + extracted metadata."
  @callback import(content :: binary(), opts :: keyword()) ::
              {:ok, %{doc: map(), meta: map()}} | {:error, term()}
end
```

- [ ] **Step 2: Write the Stub (used by hermetic tests)**

```elixir
defmodule PerfectPaper.Documents.Importer.Stub do
  @moduledoc "Deterministic importer for tests — returns a fixed, valid canonical doc."
  @behaviour PerfectPaper.Documents.Importer

  @impl true
  def import(_content, _opts) do
    {:ok,
     %{
       doc: %{
         "type" => "doc",
         "content" => [
           %{"type" => "heading", "id" => "n_stub_h", "attrs" => %{"level" => 1},
             "content" => [%{"type" => "text", "text" => "Stub Title"}]},
           %{"type" => "paragraph", "id" => "n_stub_p",
             "content" => [%{"type" => "text", "text" => "Stub body paragraph."}]}
         ]
       },
       meta: %{"title" => "Stub Title", "word_count" => 3, "source_format" => "stub"}
     }}
  end
end
```

- [ ] **Step 3: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean. (The Stub's doc is intentionally valid per `Canonical.validate_doc/1`.)

- [ ] **Step 4: Commit**

```bash
git add lib/perfect_paper/documents/importer.ex lib/perfect_paper/documents/importer/stub.ex
git commit -m "feat(documents): Importer behaviour + Stub adapter

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `Documents.Importer.Pandoc` adapter (Panpipe → our AST)

**Files:**
- Create: `lib/perfect_paper/documents/importer/pandoc.ex`
- Test: `test/perfect_paper/documents/importer/pandoc_test.exs`
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Exclude `:pandoc` tests by default**

The Pandoc adapter needs the real `pandoc` binary; keep it out of the default hermetic run. In `test/test_helper.exs`, before `ExUnit.start()` (or merge into the existing call):

```elixir
ExUnit.configure(exclude: [:pandoc])
ExUnit.start()
```

(Keep any existing sandbox setup line that follows.)

- [ ] **Step 2: Discovery spike — confirm Panpipe struct field names**

Panpipe's struct field names must match the mapping. Verify them once before coding:

Run: `iex -S mix`
Then:

```elixir
# Covers headings, inline marks, blockquote, a list, an explicit id, and a Div.
Panpipe.ast!("# Title {#intro}\n\nPlain *em* and **bold** and `code`.\n\n> quote\n\n- one\n- two\n\n::: note\nbody\n:::\n", from: :markdown)
```

Expected: a `%Panpipe.Document{children: [...]}` whose children include `%Panpipe.AST.Header{level: 1, children: [...], attr: %Panpipe.AST.Attr{identifier: "intro"}}`, `%Panpipe.AST.Para{children: [...]}`, `%Panpipe.AST.BlockQuote{children: [...]}`, `%Panpipe.AST.BulletList{children: [...]}`, `%Panpipe.AST.Div{children: [...]}`, and inlines `%Panpipe.AST.Str{string: ...}`, `%Panpipe.AST.Space{}`, `%Panpipe.AST.Emph{children: ...}`, `%Panpipe.AST.Strong{children: ...}`, `%Panpipe.AST.Code{string: ...}`. **Confirm three things the revised mapping relies on:** (a) `Header`/`CodeBlock`/`Div` carry an `:attr` field with `%Panpipe.AST.Attr{identifier: ...}`; (b) `BulletList`/`OrderedList` `children` are **lists-of-blocks** (each item a list), which `list_item/1` expects; (c) `Div.children` are **blocks**. **If any field name or shape differs, adjust the pattern matches in Step 4 accordingly.** Exit with `Ctrl-C Ctrl-C`.

- [ ] **Step 3: Write the failing test (tagged `:pandoc`)**

```elixir
defmodule PerfectPaper.Documents.Importer.PandocTest do
  use ExUnit.Case, async: true
  @moduletag :pandoc

  alias PerfectPaper.Documents.Importer.Pandoc
  alias PerfectPaper.Documents.Canonical

  test "imports markdown into a valid canonical doc" do
    md = "# Title\n\nPlain *em* and **bold** text.\n"
    assert {:ok, %{doc: doc, meta: meta}} = Pandoc.import(md, source_format: "markdown")

    # The result must validate.
    assert {:ok, _} = Canonical.validate_doc(doc)

    # Structure: heading then paragraph, each with a stable id.
    [heading, paragraph | _] = doc["content"]
    assert heading["type"] == "heading"
    assert heading["attrs"]["level"] == 1
    assert is_binary(heading["id"]) and String.starts_with?(heading["id"], "n_")
    assert Canonical.flatten_text(heading) == "Title"

    assert paragraph["type"] == "paragraph"
    assert Canonical.flatten_text(paragraph) == "Plain em and bold text."

    assert meta["source_format"] == "markdown"
  end

  test "coalesces adjacent text nodes with identical marks" do
    # '*foo bar*' is two Pandoc inlines (Str, Space, Str) under one Emph;
    # after flattening they must coalesce into a single em text node.
    assert {:ok, %{doc: doc}} = Pandoc.import("*foo bar*\n", source_format: "markdown")
    para = hd(doc["content"])
    em_nodes = Enum.filter(para["content"], &(&1["marks"] == [%{"type" => "em"}]))
    assert length(em_nodes) == 1
    assert hd(em_nodes)["text"] == "foo bar"
  end

  test "returns a deterministic error for unparseable input/format" do
    assert {:error, {:pandoc_failed, _}} =
             Pandoc.import(<<0xFF, 0xFE, 0x00>>, source_format: "docx")
  end
end
```

- [ ] **Step 4: Implement the adapter**

```elixir
defmodule PerfectPaper.Documents.Importer.Pandoc do
  @moduledoc """
  Default importer. Uses Panpipe (a Pandoc wrapper) to parse the upload into the
  Pandoc AST, then transforms it into our canonical SSoT. Pandoc/Panpipe shapes
  do not leak past this module.

  Inline marks are flattened ProseMirror-style: Pandoc nests inlines
  (`Emph [Strong [Str]]`); we accumulate active marks downward, emit flat `text`
  nodes at terminals, then coalesce adjacent same-mark text nodes.
  """
  @behaviour PerfectPaper.Documents.Importer

  alias PerfectPaper.Documents.Canonical

  @impl true
  def import(content, opts) do
    format = Keyword.get(opts, :source_format) || "markdown"

    with {:ok, %Panpipe.Document{children: children}} <- run_pandoc(content, format) do
      doc = %{"type" => "doc", "content" => Enum.flat_map(children, &block/1)}
      title = doc["content"] |> Enum.find(&(&1["type"] == "heading")) |> title_text()
      meta = %{
        "title" => title,
        "word_count" => doc |> Canonical.flatten_text() |> word_count(),
        "source_format" => format
      }

      {:ok, %{doc: doc, meta: meta}}
    end
  end

  # ── Pandoc invocation ──────────────────────────────────────────────────────

  defp run_pandoc(content, format) do
    tmp = Path.join(System.tmp_dir!(), "pp_import_#{:erlang.unique_integer([:positive])}")
    File.write!(tmp, content)

    try do
      {:ok, Panpipe.ast!(input: tmp, from: String.to_atom(format))}
    rescue
      e -> {:error, {:pandoc_failed, Exception.message(e)}}
    after
      File.rm(tmp)
    end
  end

  # ── Block mapping ───────────────────────────────────────────────────────────
  # EVERY clause returns a LIST of canonical nodes, so a Div (which wraps a list of
  # BLOCKS, not inlines) can splice its unwrapped children in. Callers flat_map over
  # block/1. Stable IDs are minted in node/4 (which also preserves source ids).

  defp block(%Panpipe.AST.Header{level: level, children: ch} = h),
    do: [node("heading", %{"level" => level}, inlines(ch), h)]

  defp block(%Panpipe.AST.Para{children: ch}), do: [node("paragraph", %{}, inlines(ch))]
  defp block(%Panpipe.AST.Plain{children: ch}), do: [node("paragraph", %{}, inlines(ch))]

  defp block(%Panpipe.AST.BlockQuote{children: ch}),
    do: [node("blockquote", %{}, Enum.flat_map(ch, &block/1))]

  defp block(%Panpipe.AST.BulletList{children: items}),
    do: [node("bullet_list", %{}, Enum.map(items, &list_item/1))]

  defp block(%Panpipe.AST.OrderedList{children: items}),
    do: [node("ordered_list", %{}, Enum.map(items, &list_item/1))]

  defp block(%Panpipe.AST.CodeBlock{string: s} = cb),
    do: [node("code_block", %{}, [%{"type" => "text", "text" => s}], cb)]

  defp block(%Panpipe.AST.HorizontalRule{}), do: [node("horizontal_rule", %{}, [])]

  # A Div wraps BLOCK children — unwrap and splice them. NEVER pass blocks to inlines/1.
  defp block(%Panpipe.AST.Div{children: ch}), do: Enum.flat_map(ch, &block/1)

  # Unknown block-level node with children → unwrap as blocks rather than scramble them.
  defp block(%{children: ch}) when is_list(ch), do: Enum.flat_map(ch, &block/1)
  defp block(_), do: []

  defp list_item(blocks) when is_list(blocks),
    do: node("list_item", %{}, Enum.flat_map(blocks, &block/1))

  defp list_item(%{children: blocks}), do: list_item(blocks)

  # ── Inline mapping: accumulate marks downward, emit flat text, then coalesce ─

  defp inlines(nodes), do: nodes |> Enum.flat_map(&inline(&1, [])) |> coalesce()

  defp inline(%Panpipe.AST.Str{string: s}, marks), do: [text(s, marks)]
  defp inline(%Panpipe.AST.Space{}, marks), do: [text(" ", marks)]
  defp inline(%Panpipe.AST.SoftBreak{}, marks), do: [text(" ", marks)]
  defp inline(%Panpipe.AST.LineBreak{}, marks), do: [text("\n", marks)]
  defp inline(%Panpipe.AST.Emph{children: ch}, marks), do: Enum.flat_map(ch, &inline(&1, add(marks, "em")))
  defp inline(%Panpipe.AST.Strong{children: ch}, marks), do: Enum.flat_map(ch, &inline(&1, add(marks, "strong")))
  defp inline(%Panpipe.AST.Code{string: s}, marks), do: [text(s, add(marks, "code"))]

  defp inline(%Panpipe.AST.Link{children: ch, target: target}, marks),
    do: Enum.flat_map(ch, &inline(&1, add_link(marks, target)))

  # Unknown inline wrapper with children → recurse, preserving marks.
  defp inline(%{children: ch}, marks) when is_list(ch), do: Enum.flat_map(ch, &inline(&1, marks))
  defp inline(_, _), do: []

  defp text(s, []), do: %{"type" => "text", "text" => s}

  # Sort marks canonically so identically-marked runs from different nesting orders
  # (`**a *b***` vs `*b **a***`) compare equal and coalesce — and so node maps are
  # structurally deterministic for tests.
  defp text(s, marks),
    do: %{"type" => "text", "text" => s, "marks" => Enum.sort_by(marks, & &1["type"])}

  defp add(marks, type) do
    if Enum.any?(marks, &(&1["type"] == type)), do: marks, else: marks ++ [%{"type" => type}]
  end

  defp add_link(marks, target) do
    href = if is_binary(target), do: target, else: elem(target, 0)
    marks ++ [%{"type" => "link", "attrs" => %{"href" => href}}]
  end

  defp coalesce(nodes) do
    nodes
    |> Enum.reduce([], fn node, acc ->
      case acc do
        [%{"type" => "text"} = prev | rest] ->
          same = Map.get(prev, "marks", []) == Map.get(node, "marks", [])

          if same and Map.has_key?(node, "text") and Map.has_key?(prev, "text"),
            do: [Map.update!(prev, "text", &(&1 <> node["text"])) | rest],
            else: [node | acc]

        _ ->
          [node | acc]
      end
    end)
    |> Enum.reverse()
  end

  # ── Node construction + meta helpers ───────────────────────────────────────

  # Always mint the stable id — it is our UNIQUE anchor/CRDT coordinate and must not
  # collide. If the source node carried an explicit identifier (e.g. `# Intro {#intro}`),
  # preserve it as attrs.source_id WITHOUT making it the stable id (Pandoc identifiers
  # are not guaranteed unique). Rendering source_id anchors / rewriting `#id` links so
  # cross-references click through is a scoped follow-up, not Step 1.
  defp node(type, attrs, content, source \\ nil) do
    attrs = maybe_put_source_id(attrs, source)
    base = %{"type" => type, "id" => mint_id(), "content" => content}
    if attrs == %{}, do: base, else: Map.put(base, "attrs", attrs)
  end

  defp maybe_put_source_id(attrs, %{attr: %Panpipe.AST.Attr{identifier: id}})
       when is_binary(id) and id != "",
       do: Map.put(attrs, "source_id", id)

  defp maybe_put_source_id(attrs, _), do: attrs

  defp mint_id, do: "n_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  defp title_text(nil), do: nil
  defp title_text(heading), do: Canonical.flatten_text(heading)

  defp word_count(""), do: 0
  defp word_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()
end
```

- [ ] **Step 5: Run the Pandoc tests explicitly**

Run: `mix test test/perfect_paper/documents/importer/pandoc_test.exs --include pandoc`
Expected: PASS. (Without `--include pandoc` the file is skipped — that's intended.)

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/documents/importer/pandoc.ex test/perfect_paper/documents/importer/pandoc_test.exs test/test_helper.exs
git commit -m "feat(documents): Pandoc importer (Panpipe -> canonical AST, marks flattened+coalesced)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: `Documents.Conversion` Oban worker

**Files:**
- Create: `lib/perfect_paper/documents/conversion.ex`
- Test: `test/perfect_paper/documents/conversion_test.exs`

- [ ] **Step 1: Write the failing test**

Uses the Stub importer (configured in `config/test.exs`) so it's hermetic.

```elixir
defmodule PerfectPaper.Documents.ConversionTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Documents
  alias PerfectPaper.Documents.{Conversion, Document}
  alias PerfectPaper.Repo

  import PerfectPaper.AccountsFixtures

  setup do
    Events.subscribe = nil
    PerfectPaper.Events.subscribe(:"document.converted")
    :ok
  end

  defp pending_doc(user) do
    {:ok, doc} =
      Documents.store_and_register(user, "irrelevant bytes", %{filename: "p.md", source_format: "markdown"})

    # store_and_register marks :converted; reset to pending for the worker path.
    {:ok, doc} = Repo.update(Document.status_changeset(doc, :pending))
    doc
  end

  test "converts a pending document and emits document.converted" do
    user = user_fixture()
    doc = pending_doc(user)

    assert :ok = perform_job(Conversion, %{"document_id" => doc.id})

    reloaded = Repo.get!(Document, doc.id)
    assert reloaded.status == :converted
    assert reloaded.canonical_doc["type"] == "doc"
    assert reloaded.canonical_meta["title"] == "Stub Title"

    assert_received {:event, %{type: :"document.converted"}}
  end

  test "cancels (no retry) and marks :failed on a deterministic read error" do
    user = user_fixture()
    {:ok, doc} = Documents.register_upload(user, %{filename: "p.md", source_format: "markdown"})
    # No storage_key was ever stored → read_content returns {:error, :enoent} (deterministic).

    assert {:cancel, _reason} = perform_job(Conversion, %{"document_id" => doc.id})
    assert Repo.get!(Document, doc.id).status == :failed
  end
end
```

> Note: `perform_job/2` comes from `Oban.Testing`. Add `use Oban.Testing, repo: PerfectPaper.Repo` to `DataCase` if not already present (check `test/support/data_case.ex`; if absent, add it in the `using` block). Also ensure `alias PerfectPaper.Events` or call `PerfectPaper.Events` fully — drop the stray `Events.subscribe = nil` line, it is illustrative; the real setup is just `PerfectPaper.Events.subscribe(:"document.converted")`.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper/documents/conversion_test.exs`
Expected: FAIL — `Conversion` undefined (and possibly `perform_job` undefined until `Oban.Testing` is wired).

- [ ] **Step 3: Wire `Oban.Testing` into DataCase (if needed)**

In `test/support/data_case.ex`, inside the `quote do ... end` of `using`, add:

```elixir
      use Oban.Testing, repo: PerfectPaper.Repo
```

- [ ] **Step 4: Implement the worker**

```elixir
defmodule PerfectPaper.Documents.Conversion do
  @moduledoc """
  Converts an uploaded document into the canonical SSoT.

  Failures are classified: DETERMINISTIC errors (bad/parse-failed input, missing
  blob, validation failure) cancel the job (`{:cancel, _}`) so Oban never retries
  them; TRANSIENT errors return `{:error, _}` for normal backoff/retry.
  """
  use Oban.Worker, queue: :documents, max_attempts: 3

  alias PerfectPaper.{Documents, Events, Repo}
  alias PerfectPaper.Documents.{Canonical, Document}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()} | {:cancel, term()}
  def perform(%Oban.Job{args: %{"document_id" => id}}) do
    document = Repo.get!(Document, id)
    {:ok, _} = Repo.update(Document.status_changeset(document, :converting))

    with {:ok, content} <- Documents.read_content(document),
         {:ok, %{doc: doc, meta: meta}} <- importer().import(content, source_format: document.source_format),
         {:ok, _} <- Canonical.validate_doc(doc),
         {:ok, converted} <- persist(document, doc, meta) do
      Events.emit(:"document.converted", %{resource: %{"document_id" => converted.id}})
      :ok
    else
      {:error, reason} ->
        {:ok, _} = Repo.update(Document.status_changeset(document, :failed))
        Events.emit(:"document.conversion_failed", %{resource: %{"document_id" => document.id, "reason" => inspect(reason)}})
        if deterministic?(reason), do: {:cancel, reason}, else: {:error, reason}
    end
  end

  defp persist(document, doc, meta) do
    document
    |> Document.canonical_changeset(%{
      canonical_doc: doc,
      canonical_meta: meta,
      source_format: document.source_format,
      status: :converted
    })
    |> Repo.update()
  end

  # Deterministic = retrying cannot help.
  defp deterministic?(:enoent), do: true
  defp deterministic?({:pandoc_failed, _}), do: true
  defp deterministic?(list) when is_list(list), do: true
  defp deterministic?(%Ecto.Changeset{}), do: true
  defp deterministic?(_), do: false

  defp importer, do: Application.get_env(:perfect_paper, :document_importer)
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/perfect_paper/documents/conversion_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/documents/conversion.ex test/perfect_paper/documents/conversion_test.exs test/support/data_case.ex
git commit -m "feat(documents): Conversion Oban worker with transient/deterministic failure classes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: `Documents` context — `ingest/3`, `get_document/1`, `canonical_doc/1`, `highlight_segments/2`

**Files:**
- Modify: `lib/perfect_paper/documents.ex`
- Test: `test/perfect_paper/documents_test.exs` (append)

- [ ] **Step 1: Write the failing test**

```elixir
  describe "ingest/3" do
    test "stores the binary, registers a pending document, and enqueues conversion" do
      user = user_fixture()

      assert {:ok, document} =
               Documents.ingest(user, "# Hello\n", %{filename: "h.md", source_format: "markdown"})

      assert document.status == :pending
      assert document.byte_size == byte_size("# Hello\n")
      assert {:ok, _content} = Documents.read_content(document)

      assert_enqueued(worker: PerfectPaper.Documents.Conversion, args: %{"document_id" => document.id})
    end
  end

  describe "highlight_segments/2" do
    @node %{"type" => "paragraph", "id" => "n_x",
            "content" => [%{"type" => "text", "text" => "hello world"}]}

    test "returns one un-highlighted segment when no anchor matches" do
      assert [%{text: "hello world", highlight: false}] =
               Documents.highlight_segments(@node, nil)
    end

    test "splits the node text at the UTF-16 range for a matching anchor" do
      segs = Documents.highlight_segments(@node, %{node_id: "n_x", from: 0, to: 5})
      assert segs == [%{text: "hello", highlight: true}, %{text: " world", highlight: false}]
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper/documents_test.exs`
Expected: FAIL — `ingest/3` / `highlight_segments/2` undefined (and `assert_enqueued` needs `Oban.Testing`, already wired in Task 6).

- [ ] **Step 3: Implement context functions**

In `lib/perfect_paper/documents.ex`, add `alias PerfectPaper.Documents.{Canonical, Conversion}` to the existing alias line, then add:

```elixir
  @doc """
  Ingests an uploaded manuscript: stores the binary, registers a `:pending`
  document, and enqueues background conversion to the canonical SSoT.
  """
  @spec ingest(struct(), binary(), map()) :: {:ok, Document.t()} | {:error, term()}
  def ingest(user, content, attrs) do
    reg =
      attrs
      |> Map.new()
      |> Map.merge(%{status: :pending, byte_size: byte_size(content)})

    with {:ok, %{storage_key: key}} <- storage().store(content, []),
         {:ok, document} <- register_upload(user, Map.put(reg, :storage_key, key)),
         {:ok, _job} <- Oban.insert(Conversion.new(%{document_id: document.id})) do
      {:ok, document}
    end
  end

  @doc "Fetches a document by id (nil if absent)."
  @spec get_document(binary()) :: Document.t() | nil
  def get_document(id), do: Repo.get(Document, id)

  @doc "Returns the canonical AST map for a document (nil until converted)."
  @spec canonical_doc(Document.t()) :: map() | nil
  def canonical_doc(%Document{canonical_doc: doc}), do: doc

  @doc """
  Splits a node's flattened text into render-ready highlight segments for the
  active comment anchor. Offsets are UTF-16 code units. Returns a single
  un-highlighted segment when the anchor does not target this node.
  """
  @spec highlight_segments(map(), %{node_id: String.t(), from: non_neg_integer(), to: non_neg_integer()} | nil) ::
          [%{text: String.t(), highlight: boolean()}]
  def highlight_segments(%{"id" => id} = node, %{node_id: id, from: from, to: to}) do
    full = Canonical.flatten_text(node)
    len = Canonical.utf16_length(full)

    [
      %{text: Canonical.utf16_slice(full, 0, from), highlight: false},
      %{text: Canonical.utf16_slice(full, from, to), highlight: true},
      %{text: Canonical.utf16_slice(full, to, len), highlight: false}
    ]
    |> Enum.reject(&(&1.text == ""))
  end

  def highlight_segments(node, _anchor),
    do: [%{text: Canonical.flatten_text(node), highlight: false}]
```

Also add `:source_format` to the keys merged through `register_upload` — it already passes through `register_changeset`, which you extended in Task 3.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/perfect_paper/documents_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/documents.ex test/perfect_paper/documents_test.exs
git commit -m "feat(documents): ingest/3 pipeline entry + canonical/highlight read helpers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Link `Session` → `Document`

**Files:**
- Create: `priv/repo/migrations/<ts>_add_document_to_sessions.exs`
- Modify: `lib/perfect_paper/history/session.ex`
- Test: `test/perfect_paper/history_test.exs` (append a focused test)

- [ ] **Step 1: Generate + write the migration**

Run: `mix ecto.gen.migration add_document_to_sessions`, then set the body:

```elixir
defmodule PerfectPaper.Repo.Migrations.AddDocumentToSessions do
  use Ecto.Migration

  def change do
    alter table(:history_sessions) do
      add :document_id, references(:documents, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:history_sessions, [:document_id])
  end
end
```

- [ ] **Step 2: Migrate**

Run: `mix ecto.migrate`
Expected: success.

- [ ] **Step 3: Write the failing test**

Append to `test/perfect_paper/history_test.exs` (use the existing fixtures/imports in that file):

```elixir
  describe "session ↔ document link" do
    test "a session can reference a source document" do
      user = user_fixture()
      {:ok, document} = PerfectPaper.Documents.register_upload(user, %{filename: "m.md"})

      {:ok, session} =
        PerfectPaper.History.begin_session(user, %{title: "M", document_id: document.id})

      assert session.document_id == document.id
    end
  end
```

> If `begin_session/2`'s arity/shape differs in this repo, adapt the call to the actual `History.begin_session` signature — the assertion (`session.document_id == document.id`) is the contract.

- [ ] **Step 4: Run to verify it fails**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: FAIL — `document_id` not cast / column unknown to the schema.

- [ ] **Step 5: Add the field + cast**

In `lib/perfect_paper/history/session.ex`, add to the schema (after `:owner_path`):

```elixir
    field :document_id, :binary_id
```

Add `:document_id` to the `create_changeset/2` cast list.

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/perfect_paper/history/session.ex test/perfect_paper/history_test.exs
git commit -m "feat(history): link Session to its source Document

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Comment anchor columns (UTF-16)

**Files:**
- Create: `priv/repo/migrations/<ts>_add_anchors_to_comments.exs`
- Modify: `lib/perfect_paper/history/comment.ex`
- Test: `test/perfect_paper/history_test.exs` (append)

- [ ] **Step 1: Generate + write the migration**

Run: `mix ecto.gen.migration add_anchors_to_comments`, then set the body:

```elixir
defmodule PerfectPaper.Repo.Migrations.AddAnchorsToComments do
  use Ecto.Migration

  def change do
    alter table(:comments) do
      add :anchor_node_id, :string
      add :anchor_from, :integer
      add :anchor_to, :integer
    end
  end
end
```

- [ ] **Step 2: Migrate**

Run: `mix ecto.migrate`
Expected: success.

- [ ] **Step 3: Write the failing test**

```elixir
  describe "comment anchors" do
    test "create_changeset casts node anchor + UTF-16 range" do
      cs =
        PerfectPaper.History.Comment.create_changeset(%PerfectPaper.History.Comment{}, %{
          session_id: Ecto.UUID.generate(),
          suggestion: "Tighten this",
          anchor_node_id: "n_b21Qd0",
          anchor_from: 3,
          anchor_to: 11
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :anchor_node_id) == "n_b21Qd0"
      assert Ecto.Changeset.get_change(cs, :anchor_from) == 3
      assert Ecto.Changeset.get_change(cs, :anchor_to) == 11
    end
  end
```

- [ ] **Step 4: Run to verify it fails**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: FAIL — anchor fields not cast / unknown.

- [ ] **Step 5: Add fields + cast**

In `lib/perfect_paper/history/comment.ex`, add to the schema (after `:position`):

```elixir
    field :anchor_node_id, :string
    field :anchor_from, :integer
    field :anchor_to, :integer
```

Add `:anchor_node_id, :anchor_from, :anchor_to` to the `create_changeset/2` cast list.

- [ ] **Step 6: Run to verify it passes**

Run: `mix test test/perfect_paper/history_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/perfect_paper/history/comment.ex test/perfect_paper/history_test.exs
git commit -m "feat(history): comment anchor columns (node_id + UTF-16 from/to)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: `DocumentComponents.render_tree/1`

**Files:**
- Create: `lib/perfect_paper_web/components/document_components.ex`
- Test: `test/perfect_paper_web/components/document_components_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule PerfectPaperWeb.DocumentComponentsTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaperWeb.DocumentComponents

  @doc_tree %{
    "type" => "doc",
    "content" => [
      %{"type" => "heading", "id" => "n_h", "attrs" => %{"level" => 1},
        "content" => [%{"type" => "text", "text" => "My Title"}]},
      %{"type" => "paragraph", "id" => "n_p",
        "content" => [
          %{"type" => "text", "text" => "Plain "},
          %{"type" => "text", "text" => "bold", "marks" => [%{"type" => "strong"}]}
        ]}
    ]
  }

  test "renders headings and paragraphs with stable node ids" do
    html = render_component(&render_tree/1, doc: @doc_tree, active_anchor: nil)
    assert html =~ ~s(id="node-n_h")
    assert html =~ "My Title"
    assert html =~ ~s(id="node-n_p")
    assert html =~ "<strong>bold</strong>"
  end

  test "escapes document text" do
    tree = %{"type" => "doc", "content" => [
      %{"type" => "paragraph", "id" => "n_x", "content" => [%{"type" => "text", "text" => "<script>x</script>"}]}
    ]}
    html = render_component(&render_tree/1, doc: tree, active_anchor: nil)
    refute html =~ "<script>x</script>"
    assert html =~ "&lt;script&gt;"
  end

  test "highlights the active comment's range only" do
    anchor = %{node_id: "n_p", from: 0, to: 5}
    html = render_component(&render_tree/1, doc: @doc_tree, active_anchor: anchor)
    assert html =~ ~s(<mark)
    assert html =~ "Plain"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper_web/components/document_components_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the component**

```elixir
defmodule PerfectPaperWeb.DocumentComponents do
  @moduledoc """
  Renders the canonical document SSoT as professional reading HEEx.

  Walks the AST; each block carries a discrete `id="node-<stable id>"`. For the
  active comment's node, the flattened text is split at the UTF-16 `[from, to)`
  range (via `Documents.highlight_segments/2`) and the hit wrapped in `<mark>`;
  all other nodes render their inline marks normally. All text is HTML-escaped.
  """
  use PerfectPaperWeb, :html

  alias PerfectPaper.Documents

  attr :doc, :map, required: true
  attr :active_anchor, :map, default: nil

  def render_tree(assigns) do
    ~H"""
    <article class="prose prose-sm max-w-none font-serif">
      <.node :for={n <- @doc["content"]} node={n} active_anchor={@active_anchor} />
    </article>
    """
  end

  attr :node, :map, required: true
  attr :active_anchor, :map, default: nil

  defp node(%{node: %{"type" => "heading"}} = assigns) do
    ~H"""
    <.heading node={@node} active_anchor={@active_anchor} />
    """
  end

  defp node(%{node: %{"type" => "paragraph"}} = assigns) do
    ~H"""
    <p id={"node-#{@node["id"]}"}><.inline_or_highlight node={@node} active_anchor={@active_anchor} /></p>
    """
  end

  defp node(%{node: %{"type" => "blockquote"}} = assigns) do
    ~H"""
    <blockquote id={"node-#{@node["id"]}"}>
      <.node :for={c <- @node["content"]} node={c} active_anchor={@active_anchor} />
    </blockquote>
    """
  end

  defp node(%{node: %{"type" => "bullet_list"}} = assigns) do
    ~H"""
    <ul id={"node-#{@node["id"]}"}>
      <.node :for={c <- @node["content"]} node={c} active_anchor={@active_anchor} />
    </ul>
    """
  end

  defp node(%{node: %{"type" => "ordered_list"}} = assigns) do
    ~H"""
    <ol id={"node-#{@node["id"]}"}>
      <.node :for={c <- @node["content"]} node={c} active_anchor={@active_anchor} />
    </ol>
    """
  end

  defp node(%{node: %{"type" => "list_item"}} = assigns) do
    ~H"""
    <li id={"node-#{@node["id"]}"}>
      <.node :for={c <- @node["content"]} node={c} active_anchor={@active_anchor} />
    </li>
    """
  end

  defp node(%{node: %{"type" => "code_block"}} = assigns) do
    ~H"""
    <pre id={"node-#{@node["id"]}"}><code>{PerfectPaper.Documents.Canonical.flatten_text(@node)}</code></pre>
    """
  end

  defp node(%{node: %{"type" => "horizontal_rule"}} = assigns) do
    ~H"""
    <hr id={"node-#{@node["id"]}"} />
    """
  end

  defp node(assigns) do
    ~H"""
    <p id={"node-#{@node["id"]}"}><.inline_or_highlight node={@node} active_anchor={@active_anchor} /></p>
    """
  end

  attr :node, :map, required: true
  attr :active_anchor, :map, default: nil

  defp heading(%{node: %{"attrs" => %{"level" => 1}}} = assigns),
    do: ~H|<h1 id={"node-#{@node["id"]}"}><.inline_or_highlight node={@node} active_anchor={@active_anchor} /></h1>|

  defp heading(%{node: %{"attrs" => %{"level" => 2}}} = assigns),
    do: ~H|<h2 id={"node-#{@node["id"]}"}><.inline_or_highlight node={@node} active_anchor={@active_anchor} /></h2>|

  defp heading(assigns),
    do: ~H|<h3 id={"node-#{@node["id"]}"}><.inline_or_highlight node={@node} active_anchor={@active_anchor} /></h3>|

  attr :node, :map, required: true
  attr :active_anchor, :map, default: nil

  # Active node → highlight segments (marks dropped within the highlighted node,
  # by design — see spec §8). Inactive node → inline content with marks.
  defp inline_or_highlight(%{node: %{"id" => id}, active_anchor: %{node_id: id}} = assigns) do
    assigns = assign(assigns, :segments, Documents.highlight_segments(assigns.node, assigns.active_anchor))

    ~H"""
    <%= for seg <- @segments do %><mark :if={seg.highlight} class="rounded-sm bg-accent/20">{seg.text}</mark><span :if={!seg.highlight}>{seg.text}</span><% end %>
    """
  end

  defp inline_or_highlight(assigns) do
    ~H"""
    <.inline :for={c <- @node["content"]} text={c} />
    """
  end

  attr :text, :map, required: true

  defp inline(%{text: %{"type" => "text", "marks" => marks}} = assigns) do
    assigns = assign(assigns, :marks, Enum.map(marks, & &1["type"]))
    wrap_marks(assigns)
  end

  defp inline(%{text: %{"type" => "text"}} = assigns), do: ~H"{@text["text"]}"
  defp inline(assigns), do: ~H""

  defp wrap_marks(%{marks: marks} = assigns) do
    cond do
      "code" in marks -> ~H|<code>{@text["text"]}</code>|
      "strong" in marks and "em" in marks -> ~H|<strong><em>{@text["text"]}</em></strong>|
      "strong" in marks -> ~H|<strong>{@text["text"]}</strong>|
      "em" in marks -> ~H|<em>{@text["text"]}</em>|
      "link" in marks -> ~H|<a href={link_href(@text)}>{@text["text"]}</a>|
      true -> ~H"{@text["text"]}"
    end
  end

  defp link_href(%{"marks" => marks}) do
    case Enum.find(marks, &(&1["type"] == "link")) do
      %{"attrs" => %{"href" => href}} -> href
      _ -> "#"
    end
  end
end
```

> HEEx auto-escapes `{...}` interpolations, so document text is safe by construction — the escape test verifies it.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/perfect_paper_web/components/document_components_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/components/document_components.ex test/perfect_paper_web/components/document_components_test.exs
git commit -m "feat(web): DocumentComponents.render_tree — professional AST rendering + UTF-16 highlight

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 11: Render the linked document in `WorkspaceLive`

**Files:**
- Modify: `lib/perfect_paper_web/live/workspace_live.ex`
- Test: `test/perfect_paper_web/live/workspace_live_test.exs` (append, or create if absent)

- [ ] **Step 1: Write the failing test**

```elixir
  test "renders the linked document's canonical body", %{conn: conn} do
    user = user_fixture()

    {:ok, document} =
      PerfectPaper.Documents.store_and_register(user, "# Linked\n", %{filename: "l.md", source_format: "markdown"})

    {:ok, document} =
      document
      |> PerfectPaper.Documents.Document.canonical_changeset(%{
        canonical_doc: %{"type" => "doc", "content" => [
          %{"type" => "heading", "id" => "n_lh", "attrs" => %{"level" => 1},
            "content" => [%{"type" => "text", "text" => "Linked Manuscript"}]}
        ]},
        status: :converted
      })
      |> PerfectPaper.Repo.update()

    session = session_fixture(user, %{document_id: document.id, title: "Linked Manuscript"})

    {:ok, _lv, html} = live(conn |> log_in_user(user), ~p"/workspace/#{session.id}")
    assert html =~ "Linked Manuscript"
    assert html =~ ~s(id="node-n_lh")
  end
```

> Use the workspace route actually defined in `router.ex` (the example assumes `~p"/workspace/#{id}"`); adapt the path and `session_fixture` arity to this repo's helpers. The contract is: the canonical body renders via `node-<id>` markers.

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper_web/live/workspace_live_test.exs`
Expected: FAIL — the canonical body / `node-n_lh` is not rendered yet.

- [ ] **Step 3: Load + render the document**

In `lib/perfect_paper_web/live/workspace_live.ex`:

- add `alias PerfectPaper.Documents` to the existing alias line;
- in `mount/3`, after fetching `session`, assign the canonical doc:

```elixir
        canonical =
          case session.document_id && Documents.get_document(session.document_id) do
            %PerfectPaper.Documents.Document{} = d -> Documents.canonical_doc(d)
            _ -> nil
          end

        {:ok,
         assign(socket,
           page_title: session.title || "Workspace",
           session: session,
           canonical_doc: canonical,
           active_anchor: nil,
           show_chat: false,
           show_overall: true,
           sort: :relevance
         )}
```

- in `render/2`, render the canonical body when present, just inside `<.review_panes …>` (above the existing faked body it currently shows). Add near the top of the component's left-pane slot, or wrap with a conditional:

```elixir
      <.review_panes
        title={@session.title || "Untitled manuscript"}
        comments={@session.comments}
        overall_feedback={@session.overall_feedback}
        show_overall={@show_overall}
        sort={@sort}
      >
        <:document :if={@canonical_doc}>
          <PerfectPaperWeb.DocumentComponents.render_tree doc={@canonical_doc} active_anchor={@active_anchor} />
        </:document>
        <:chat :if={@show_chat}>
          <!-- unchanged -->
        </:chat>
      </.review_panes>
```

> If `review_panes/1` does not yet declare a `:document` slot, add `slot :document` to it in `lib/perfect_paper_web/components/review_components.ex` and render `{render_slot(@document)}` in its left/manuscript pane, falling back to the existing faked body when the slot is empty. Keep that change minimal and local.

> **Scope note — `active_anchor` is wired but inert in Step 1.** The assign is bound so highlighting works the moment an anchor is set, but the `handle_event` that *sets* `active_anchor` (clicking a comment to highlight its span) ships with the feedback work in Step 2/3 — there are no LLM-generated anchors to highlight until then, so building the click handler now would be dead UI.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/perfect_paper_web/live/workspace_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/live/workspace_live.ex lib/perfect_paper_web/components/review_components.ex test/perfect_paper_web/live/workspace_live_test.exs
git commit -m "feat(web): render the linked document's canonical body in WorkspaceLive

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 12: Pre-merge verification + merge

- [ ] **Step 1: Full precommit**

Run: `mix precommit`
Expected: compiles warnings-as-errors, format clean, full suite green. (Pandoc-tagged tests stay excluded; run them explicitly if Pandoc is installed: `mix test --include pandoc`.)

- [ ] **Step 2: Fix anything red** — broken tests are in scope; do not proceed while any test fails.

- [ ] **Step 3: Merge to main**

```bash
git checkout main
git merge --no-ff feat/doc-ssot-ingestion -m "feat: document SSoT + ingestion (Step 1)"
```

Expected: clean merge. Report: "committed and merged back to main with no issues."

---

## Self-Review (completed during authoring)

**Spec coverage** — every spec section maps to a task: canonical model + node set + stable IDs (Task 2, 5); schemaless recursive validation, not Ecto embeds (Task 2 + Task 3 `validate_change`); UTF-16 anchors (Task 2 helpers, Task 9 columns, Task 10 highlight); JSONB columns + reuse of `status` enum (Task 3); ingestion pipeline as Oban job (Task 6, 7); `Importer` behaviour + Pandoc adapter with mark accumulation + coalescing (Task 4, 5); transient/deterministic failure classification → `{:cancel, _}` (Task 6); `Events` post-commit emit + type whitelist (Task 1, 6); `Session.document_id` link (Task 8); rendering (Task 10, 11). Out-of-scope (PDF, live co-editing) intentionally absent.

**Placeholders** — none; every code step contains complete code. The two "adapt to this repo's signature" notes (Task 8 `begin_session`, Task 11 route/`session_fixture`) are because those helpers' exact arities weren't read during planning; each states the concrete contract to satisfy.

**Type consistency** — importer returns `%{doc, meta}` (Task 4/5) consumed identically by the worker (Task 6) and persisted via `canonical_changeset` casting `[:canonical_doc, :canonical_meta, :source_format, :status]` (Task 3); `highlight_segments/2` shape `%{text, highlight}` matches its consumer in Task 10; anchor map shape `%{node_id, from, to}` consistent across Tasks 7, 10, 11; event atoms `:"document.converted"`/`:"document.conversion_failed"` match the whitelist added in Task 1.
