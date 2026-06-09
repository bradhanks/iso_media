# panpipe ⇄ perfect_paper Canonical Boundary — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `panpipe` the single authoritative document-model + import library, and have `perfect_paper` consume it via a git dependency — deleting `perfect_paper`'s duplicate canonical engine.

**Architecture:** panpipe gains a map-based boundary (`Canonical.import_document/2`, `Canonical.validate/1`, and `Canonical.Text` UTF-16 helpers). perfect_paper swaps its in-repo `Documents.Importer.Pandoc` + `Documents.Canonical` for a thin `Importer.Panpipe` adapter and direct `Canonical.*` calls, adapting its renderer/anchoring to the `attrs["id"]` node shape.

**Tech Stack:** Elixir, panpipe (git dep), pandoc CLI, Phoenix LiveView, Ecto.

**Spec:** `docs/superpowers/specs/2026-06-04-panpipe-canonical-boundary-design.md`

**Repos:** Phase A runs in `/Users/bradhanks/panpipe` (branch `master`). Phase B runs in `/Users/bradhanks/perfect_paper` (branch `feat/panpipe-canonical-boundary`, off `main`).

**Conventions:** `mix test <path>` → RED, implement, GREEN, `mix format`, commit. In panpipe, prefix test commands with `export PATH="/opt/homebrew/bin:$PATH"` so pandoc resolves.

---

## File map

### Phase A — panpipe (`/Users/bradhanks/panpipe`)
| File | Change |
|------|--------|
| `lib/canonical/text.ex` | **New.** `flatten_text/1` (map→string), `utf16_length/1`, `utf16_slice/3` (from,to). |
| `lib/canonical.ex` | Add `import_document/2` (map+meta), map-aware `validate/1`, and `defdelegate` for the three `Canonical.Text` helpers. |
| `test/canonical/text_test.exs` | **New.** |
| `test/canonical/boundary_test.exs` | **New.** `import_document/2` + `validate/1`. |

### Phase B — perfect_paper (`/Users/bradhanks/perfect_paper`)
| File | Change |
|------|--------|
| `mix.exs` | `{:panpipe, "~> 0.3"}` → git dep at tag `v0.4.0-canonical`. |
| `config/config.exs` | `:document_importer` → `Importer.Panpipe`. |
| `lib/perfect_paper/documents/importer/panpipe.ex` | **New.** Adapter → `Canonical.import_document/2`. |
| `lib/perfect_paper/documents/conversion.ex` | validate via `Canonical.validate/1` (`:ok` contract); drop `Canonical` alias. |
| `lib/perfect_paper/documents/document.ex` | `canonical_changeset` validate via `Canonical.validate/1`. |
| `lib/perfect_paper/documents.ex` | `highlight_segments/2` → `Canonical.*` + `attrs["id"]` match. |
| `lib/perfect_paper_web/components/document_components.ex` | `attrs["id"]` ids; safe block fallback; `flatten_text` via panpipe. |
| `lib/perfect_paper/documents/importer/pandoc.ex` | **Delete.** |
| `lib/perfect_paper/documents/canonical.ex` | **Delete.** |
| test files | Update adapter/renderer/validate expectations. |

---

# PHASE A — panpipe

## Task A1: `Canonical.Text` (flatten + UTF-16 helpers)

**Files:**
- Create: `/Users/bradhanks/panpipe/lib/canonical/text.ex`
- Test: `/Users/bradhanks/panpipe/test/canonical/text_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/text_test.exs
defmodule Canonical.TextTest do
  use ExUnit.Case, async: true
  alias Canonical.Text

  @doc_map %{
    "type" => "doc",
    "content" => [
      %{"type" => "paragraph", "attrs" => %{"id" => "p"},
        "content" => [
          %{"type" => "text", "text" => "Hi "},
          %{"type" => "text", "text" => "world", "marks" => [%{"type" => "strong"}]}
        ]}
    ]
  }

  test "flatten_text/1 concatenates descendant text from a node map" do
    assert Text.flatten_text(@doc_map) == "Hi world"
  end

  test "utf16_length/1 counts UTF-16 code units (surrogate pairs = 2)" do
    assert Text.utf16_length("abc") == 3
    # 😂 (U+1F602) is one codepoint but TWO UTF-16 code units
    assert Text.utf16_length("a😂b") == 4
  end

  test "utf16_slice/3 uses (from, to) end-offsets and is surrogate-safe" do
    assert Text.utf16_slice("hello", 0, 2) == "he"
    assert Text.utf16_slice("hello", 2, 5) == "llo"
    # slice that lands on the emoji's two code units returns the whole emoji
    assert Text.utf16_slice("a😂b", 1, 3) == "😂"
    # clamps past the end; empty when from==to
    assert Text.utf16_slice("hi", 1, 99) == "i"
    assert Text.utf16_slice("hi", 1, 1) == ""
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="/opt/homebrew/bin:$PATH"; mix test test/canonical/text_test.exs`
Expected: FAIL — `Canonical.Text` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/canonical/text.ex
defmodule Canonical.Text do
  @moduledoc """
  Text flattening and UTF-16 offset helpers for canonical document maps.

  `flatten_text/1` takes a node **map** (string keys) and returns the concatenated
  descendant text. `utf16_length/1` and `utf16_slice/3` operate on the resulting
  **string** and compute offsets in UTF-16 code units (to align with the JS /
  ProseMirror frontend, which addresses text in UTF-16). `utf16_slice/3` takes
  `(string, from, to)` END-offsets (not a length).
  """

  @spec flatten_text(map()) :: String.t()
  def flatten_text(node), do: node |> io_text() |> IO.iodata_to_binary()

  defp io_text(%{"type" => "text", "text" => t}) when is_binary(t), do: t
  defp io_text(%{"content" => content}) when is_list(content), do: Enum.map(content, &io_text/1)
  defp io_text(_), do: []

  @spec utf16_length(String.t()) :: non_neg_integer()
  def utf16_length(string) when is_binary(string) do
    div(byte_size(:unicode.characters_to_binary(string, :utf8, {:utf16, :little})), 2)
  end

  @spec utf16_slice(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def utf16_slice(string, from, to)
      when is_binary(string) and is_integer(from) and is_integer(to) and from >= 0 and to >= from do
    u16 = :unicode.characters_to_binary(string, :utf8, {:utf16, :little})
    total = byte_size(u16)
    byte_from = min(from * 2, total)
    byte_to = min(to * 2, total)
    len = byte_to - byte_from

    if len <= 0 do
      ""
    else
      u16 |> binary_part(byte_from, len) |> :unicode.characters_to_binary({:utf16, :little}, :utf8)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="/opt/homebrew/bin:$PATH"; mix test test/canonical/text_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/bradhanks/panpipe
mix format lib/canonical/text.ex test/canonical/text_test.exs
git add lib/canonical/text.ex test/canonical/text_test.exs
git commit -m "feat(canonical): add Text module (flatten + UTF-16 offset helpers)"
```

---

## Task A2: map-based boundary — `validate/1` and `import_document/2`

**Files:**
- Modify: `/Users/bradhanks/panpipe/lib/canonical.ex`
- Test: `/Users/bradhanks/panpipe/test/canonical/boundary_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/canonical/boundary_test.exs
defmodule Canonical.BoundaryTest do
  use ExUnit.Case, async: true

  test "validate/1 accepts a plain PM JSON map" do
    {:ok, struct_doc, _} = Canonical.ingest("# Hi")
    map = Canonical.to_pm_json(struct_doc)
    assert Canonical.validate(map) == :ok
  end

  test "validate/1 rejects a malformed map with {:error, [%{path, message}]}" do
    bad = %{"type" => "doc", "content" => [%{"type" => "bogus_node"}]}
    assert {:error, [%{path: _, message: msg} | _]} = Canonical.validate(bad)
    assert msg =~ "unknown node type"
  end

  test "import_document/2 returns a map doc + meta from a markdown string" do
    {:ok, %{doc: doc, meta: meta, warnings: warnings}} =
      Canonical.import_document("# Title\n\nHello **world**", source_format: "markdown")

    assert doc["type"] == "doc"
    # id lives in attrs, not top-level
    heading = Enum.find(doc["content"], &(&1["type"] == "heading"))
    assert is_binary(heading["attrs"]["id"])
    refute Map.has_key?(heading, "id")

    assert meta["title"] == "Title"
    assert meta["word_count"] == 3
    assert meta["source_format"] == "markdown"
    assert is_list(warnings)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export PATH="/opt/homebrew/bin:$PATH"; mix test test/canonical/boundary_test.exs`
Expected: FAIL — `import_document/2` undefined; `validate/1` on a map raises (current `validate` expects a `%Node{}`).

- [ ] **Step 3: Write minimal implementation**

Replace the existing `validate/2` in `lib/canonical.ex` and add the new functions + delegates. The current file ends:

```elixir
  def validate(node, schema \\ Pandoc.schema()), do: Import.validate(node, schema)

  @doc "The default schema (the custom Pandoc-covering schema)."
  def schema, do: Pandoc.schema()
end
```

Change the `alias` line and that tail to:

```elixir
  alias Canonical.{Import, PM, Text}
  alias Canonical.Schema.Pandoc

  defdelegate ingest(input_or_opts, opts \\ []), to: Import
  defdelegate from_panpipe(document, opts \\ []), to: Import
  defdelegate to_pm_json(node), to: Import
  defdelegate from_pm_json(map), to: Import

  defdelegate flatten_text(node), to: Text
  defdelegate utf16_length(string), to: Text
  defdelegate utf16_slice(string, from, to), to: Text

  @doc """
  Validates a canonical doc. Accepts either a `%Canonical.Node{}` or a plain PM
  JSON map. Returns `:ok | {:error, [%{path: String.t(), message: String.t()}]}`.
  """
  def validate(doc, schema \\ Pandoc.schema())
  def validate(%Canonical.Node{} = node, schema), do: Import.validate(node, schema)
  def validate(doc, schema) when is_map(doc), do: doc |> PM.from_json() |> Import.validate(schema)

  @doc """
  Imports a source document into a PM JSON map + metadata.

  Accepts a binary (temp-filed for pandoc, format from `opts[:source_format]`) or a
  panpipe options keyword list (e.g. `[input: path, from: :docx]`). Returns
  `{:ok, %{doc: map(), meta: map(), warnings: [term()]}} | {:error, term()}`.
  """
  def import_document(content_or_opts, opts \\ [])

  def import_document(content, opts) when is_binary(content) do
    ast_opts =
      case Keyword.get(opts, :source_format) do
        nil -> []
        fmt -> [from: String.to_atom(fmt)]
      end

    tmp = Path.join(System.tmp_dir!(), "canonical_import_#{:erlang.unique_integer([:positive])}")
    File.write!(tmp, content)

    try do
      run_import([input: tmp] ++ ast_opts, opts)
    after
      File.rm(tmp)
    end
  end

  def import_document(in_opts, opts) when is_list(in_opts), do: run_import(in_opts, opts)

  defp run_import(in_opts, opts) do
    canonical_opts = Keyword.take(opts, [:id_generator, :preserve_soft_breaks, :on_invalid])

    case ingest(in_opts, canonical_opts) do
      {:ok, struct_doc, warnings} ->
        doc = PM.to_json(struct_doc)
        {:ok, %{doc: doc, meta: build_meta(doc, opts), warnings: warnings}}

      {:error, _} = error ->
        error
    end
  end

  defp build_meta(doc, opts) do
    title =
      case doc["content"] |> List.wrap() |> Enum.find(&(&1["type"] == "heading")) do
        nil -> nil
        heading -> Text.flatten_text(heading)
      end

    %{
      "title" => title,
      "word_count" => doc |> Text.flatten_text() |> word_count(),
      "source_format" => Keyword.get(opts, :source_format)
    }
  end

  defp word_count(""), do: 0
  defp word_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()

  @doc "The default schema (the custom Pandoc-covering schema)."
  def schema, do: Pandoc.schema()
end
```

Also remove the now-duplicate `alias`/`defdelegate` lines at the TOP of the module that this replaces (the file already had `alias Canonical.Import` / `alias Canonical.Schema.Pandoc` and the four `defdelegate`s + `def validate`). Ensure there is exactly one `alias` block and one set of delegates — i.e. delete the original top-of-module `alias Import` line, the four original `defdelegate`s, and the original `def validate(node, schema \\ ...)`, since they're re-declared above.

- [ ] **Step 4: Run test to verify it passes**

Run: `export PATH="/opt/homebrew/bin:$PATH"; mix test test/canonical/boundary_test.exs && mix test`
Expected: boundary PASS (3 tests); full panpipe suite still green (105 + new).

- [ ] **Step 5: Commit**

```bash
cd /Users/bradhanks/panpipe
mix format lib/canonical.ex test/canonical/boundary_test.exs
git add lib/canonical.ex test/canonical/boundary_test.exs
git commit -m "feat(canonical): add map-based boundary (import_document/2, validate/1, text delegates)"
```

---

## Task A3: tag and push the panpipe fork (operational — confirm before pushing)

**No code.** This publishes the library so perfect_paper's git dep can fetch it.

- [ ] **Step 1: Confirm full suite + format**

```bash
cd /Users/bradhanks/panpipe
export PATH="/opt/homebrew/bin:$PATH"
mix format --check-formatted && mix test
```
Expected: clean format; all tests pass.

- [ ] **Step 2: Confirm with the user before any push** (outward-facing). Then tag and push:

```bash
cd /Users/bradhanks/panpipe
git tag v0.4.0-canonical
git push origin master
git push origin v0.4.0-canonical
```

- [ ] **Step 3: Verify the tag is on the remote**

Run: `git ls-remote --tags origin | grep v0.4.0-canonical`
Expected: the tag's SHA is listed.

- [ ] **Step 4: Note fork visibility.** If `github.com/bradhanks/panpipe` is **private**, the perfect_paper dep must use SSH (`git@github.com:bradhanks/panpipe.git`) and CI/deploy must have a key/token. Record which URL form is used.

---

# PHASE B — perfect_paper

## Task B1: depend on panpipe (git) and flip the importer config

**Files:**
- Modify: `/Users/bradhanks/perfect_paper/mix.exs`
- Modify: `/Users/bradhanks/perfect_paper/config/config.exs`

- [ ] **Step 1: Edit `mix.exs`** — replace `{:panpipe, "~> 0.3"}` with:

```elixir
      {:panpipe, git: "https://github.com/bradhanks/panpipe.git", tag: "v0.4.0-canonical"},
```
(Use the `git@github.com:...` SSH form instead if the fork is private — see Task A3 Step 4.)

- [ ] **Step 2: Fetch**

```bash
cd /Users/bradhanks/perfect_paper
mix deps.get
```
Expected: panpipe fetched at tag `v0.4.0-canonical`; `mix.lock` updated.

- [ ] **Step 3: Verify the boundary is reachable**

```bash
export PATH="/opt/homebrew/bin:$PATH"
mix run -e 'IO.inspect(Canonical.validate(%{"type"=>"doc","content"=>[]}))'
```
Expected: prints `:ok` (empty doc is valid: `doc = block+`? No — `doc` requires `block+`, so an empty doc is INVALID). Expected actually: `{:error, [%{...}]}`. Either way it proves `Canonical.*` resolves from the dep. (If it prints an error tuple, that's success for *reachability*.)

- [ ] **Step 4: Flip importer default** in `config/config.exs` line 33:

```elixir
config :perfect_paper, :document_importer, PerfectPaper.Documents.Importer.Panpipe
```
(`config/test.exs` keeps `Importer.Stub` — unchanged.)

- [ ] **Step 5: Commit**

```bash
cd /Users/bradhanks/perfect_paper
git add mix.exs mix.lock config/config.exs
git commit -m "build(deps): depend on panpipe canonical fork (git tag); default importer Panpipe"
```

---

## Task B2: `Documents.Importer.Panpipe` adapter

**Files:**
- Create: `/Users/bradhanks/perfect_paper/lib/perfect_paper/documents/importer/panpipe.ex`
- Test: `/Users/bradhanks/perfect_paper/test/perfect_paper/documents/importer/panpipe_test.exs`

- [ ] **Step 1: Write the failing test** (needs pandoc + a docx; build the docx in setup)

```elixir
# test/perfect_paper/documents/importer/panpipe_test.exs
defmodule PerfectPaper.Documents.Importer.PanpipeTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Documents.Importer.Panpipe

  @tag :pandoc
  test "imports markdown bytes into a canonical map + meta" do
    {:ok, %{doc: doc, meta: meta}} =
      Panpipe.import("# Title\n\nHello **world**", source_format: "markdown")

    assert doc["type"] == "doc"
    heading = Enum.find(doc["content"], &(&1["type"] == "heading"))
    assert is_binary(heading["attrs"]["id"])
    assert meta["title"] == "Title"
    assert meta["source_format"] == "markdown"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/bradhanks/perfect_paper && export PATH="/opt/homebrew/bin:$PATH"; mix test test/perfect_paper/documents/importer/panpipe_test.exs`
Expected: FAIL — `Importer.Panpipe` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/perfect_paper/documents/importer/panpipe.ex
defmodule PerfectPaper.Documents.Importer.Panpipe do
  @moduledoc """
  Default importer adapter. Delegates to the panpipe `Canonical` library, which
  owns the Pandoc→canonical transform. Returns the boundary contract
  `{:ok, %{doc: map(), meta: map()}}`; panpipe's `warnings` are dropped here.
  """
  @behaviour PerfectPaper.Documents.Importer

  @impl true
  def import(content, opts) do
    case Canonical.import_document(content, opts) do
      {:ok, %{doc: doc, meta: meta}} -> {:ok, %{doc: doc, meta: meta}}
      {:error, _} = error -> error
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/bradhanks/perfect_paper && export PATH="/opt/homebrew/bin:$PATH"; mix test test/perfect_paper/documents/importer/panpipe_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
cd /Users/bradhanks/perfect_paper
mix format lib/perfect_paper/documents/importer/panpipe.ex test/perfect_paper/documents/importer/panpipe_test.exs
git add lib/perfect_paper/documents/importer/panpipe.ex test/perfect_paper/documents/importer/panpipe_test.exs
git commit -m "feat(documents): add Importer.Panpipe adapter delegating to panpipe Canonical"
```

---

## Task B3: repoint validation to `Canonical.validate/1`

**Files:**
- Modify: `/Users/bradhanks/perfect_paper/lib/perfect_paper/documents/document.ex` (`canonical_changeset/2`)
- Modify: `/Users/bradhanks/perfect_paper/lib/perfect_paper/documents/conversion.ex`

- [ ] **Step 1: Update `document.ex` `canonical_changeset/2`** — replace the `validate_change` body:

```elixir
  def canonical_changeset(document, attrs) do
    document
    |> cast(attrs, [:canonical_doc, :canonical_meta, :source_format, :status])
    |> validate_change(:canonical_doc, fn :canonical_doc, doc ->
      case Canonical.validate(doc) do
        :ok ->
          []

        {:error, violations} ->
          first = hd(violations)
          [canonical_doc: "[at #{first.path}] #{first.message}"]
      end
    end)
  end
```

- [ ] **Step 2: Update `conversion.ex`** — change the alias (line 12) and the validate clause (line 23):

```elixir
  # line 12: drop Canonical (it now refers to the panpipe top-level module)
  alias PerfectPaper.Documents.Document
```
```elixir
  # line ~23: panpipe validate returns :ok (not {:ok, _})
         :ok <- Canonical.validate(doc),
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/bradhanks/perfect_paper && export PATH="/opt/homebrew/bin:$PATH"; mix test test/perfect_paper/documents/conversion_test.exs`
Expected: PASS (the worker test should still convert `:pending → :converted`).

- [ ] **Step 4: Commit**

```bash
cd /Users/bradhanks/perfect_paper
mix format lib/perfect_paper/documents/document.ex lib/perfect_paper/documents/conversion.ex
git add lib/perfect_paper/documents/document.ex lib/perfect_paper/documents/conversion.ex
git commit -m "refactor(documents): validate canonical docs via panpipe Canonical.validate/1"
```

---

## Task B4: repoint `highlight_segments/2` to panpipe + `attrs["id"]`

**Files:**
- Modify: `/Users/bradhanks/perfect_paper/lib/perfect_paper/documents.ex`
- Test: `/Users/bradhanks/perfect_paper/test/perfect_paper/documents_test.exs` (highlight assertions)

- [ ] **Step 1: Update the failing/affected test** — anchors now key off `attrs["id"]`. Add/adjust:

```elixir
  test "highlight_segments/2 splits on the active anchor by attrs id (UTF-16)" do
    node = %{
      "type" => "paragraph",
      "attrs" => %{"id" => "n1"},
      "content" => [%{"type" => "text", "text" => "hello world"}]
    }

    segs = PerfectPaper.Documents.highlight_segments(node, %{node_id: "n1", from: 0, to: 5})
    assert segs == [%{text: "hello", highlight: true}, %{text: " world", highlight: false}]

    # non-matching anchor → single un-highlighted segment
    assert PerfectPaper.Documents.highlight_segments(node, %{node_id: "other", from: 0, to: 1}) ==
             [%{text: "hello world", highlight: false}]
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /Users/bradhanks/perfect_paper && export PATH="/opt/homebrew/bin:$PATH"; mix test test/perfect_paper/documents_test.exs -k "highlight"`
Expected: FAIL — current code matches top-level `%{"id" => id}` and calls `Documents.Canonical.*`.

- [ ] **Step 3: Update `documents.ex`** — replace the two `highlight_segments/2` clauses (and any `Documents.Canonical` references):

```elixir
  def highlight_segments(%{"attrs" => %{"id" => id}} = node, %{node_id: id, from: from, to: to}) do
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

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/bradhanks/perfect_paper && export PATH="/opt/homebrew/bin:$PATH"; mix test test/perfect_paper/documents_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/bradhanks/perfect_paper
mix format lib/perfect_paper/documents.ex test/perfect_paper/documents_test.exs
git add lib/perfect_paper/documents.ex test/perfect_paper/documents_test.exs
git commit -m "refactor(documents): highlight_segments via panpipe Canonical + attrs id"
```

---

## Task B5: adapt the renderer to `attrs["id"]` + safe block fallback

**Files:**
- Modify: `/Users/bradhanks/perfect_paper/lib/perfect_paper_web/components/document_components.ex`
- Test: `/Users/bradhanks/perfect_paper/test/perfect_paper_web/components/document_components_test.exs`

- [ ] **Step 1: Add failing tests** — ids come from `attrs["id"]`, and an unknown block type renders as a block container with its block children (NOT swallowed by the inline path):

```elixir
  test "renders block id from attrs and a safe container for unknown block types" do
    doc = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "attrs" => %{"id" => "p1"},
          "content" => [%{"type" => "text", "text" => "hi"}]},
        %{"type" => "table", "attrs" => %{"id" => "t1"},
          "content" => [
            %{"type" => "table_row", "attrs" => %{"id" => "r1"},
              "content" => [
                %{"type" => "table_cell", "attrs" => %{"id" => "c1"},
                  "content" => [%{"type" => "paragraph", "attrs" => %{"id" => "p2"},
                    "content" => [%{"type" => "text", "text" => "cell"}]}]}
              ]}
          ]}
      ]
    }

    html = render_component(&PerfectPaperWeb.DocumentComponents.render_tree/1, doc: doc, active_anchor: nil)
    assert html =~ ~s(id="node-p1")
    # unknown block (table) renders as a container exposing its id, and the deep
    # cell paragraph text survives (proving block children were recursed, not dropped)
    assert html =~ ~s(id="node-t1")
    assert html =~ "cell"
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /Users/bradhanks/perfect_paper && export PATH="/opt/homebrew/bin:$PATH"; mix test test/perfect_paper_web/components/document_components_test.exs`
Expected: FAIL — ids use top-level `@node["id"]` (nil now), and `table` hits the inline fallback which drops the cell text.

- [ ] **Step 3: Implement** — in `document_components.ex`:

(a) Replace every `@node["id"]` with `@node["attrs"]["id"]` (in `paragraph`, `blockquote`, `bullet_list`, `ordered_list`, `list_item`, `code_block`, `horizontal_rule`, all three `heading` clauses).

(b) Replace `Documents.Canonical.flatten_text(@node)` in the `code_block` clause with `Canonical.flatten_text(@node)`.

(c) Replace the generic fallback `block/1` clause with a **block-safe** container that recurses children as blocks when present, else renders inline:

```elixir
  defp block(%{node: %{"content" => content}} = assigns) when is_list(content) do
    ~H"""
    <div id={"node-#{@node["attrs"]["id"]}"} data-node-type={@node["type"]}>
      <.block :for={c <- @node["content"]} node={c} active_anchor={@active_anchor} />
    </div>
    """
  end

  defp block(assigns) do
    ~H"""
    <p id={"node-#{@node["attrs"]["id"]}"}>
      <.inline_or_highlight node={@node} active_anchor={@active_anchor} />
    </p>
    """
  end
```

(d) Fix the active-anchor match clause (it matched top-level id). Replace the first `inline_or_highlight/1` clause's head so the node's `attrs["id"]` and the anchor's `node_id` bind to the **same** variable `id` (pure pattern matching — do NOT use a guard, because map Access `node["attrs"]["id"]` is not allowed in guards):

```elixir
  defp inline_or_highlight(
         %{node: %{"attrs" => %{"id" => node_id}}, active_anchor: %{node_id: anchor_id}} = assigns
       )
       when node_id == anchor_id and not is_nil(anchor_id) do
```
> Bind `node_id` (from the node's `attrs`) and `anchor_id` (from the active anchor) in the **pattern**, then compare them in the **guard** — map Access (`node["attrs"]["id"]`) is forbidden in guards, but comparing already-bound variables is allowed. The `not is_nil(anchor_id)` clause prevents a `nil == nil` false match. When `active_anchor` is `nil`, or `attrs["id"]` is missing, or the ids differ, this clause doesn't match and the second `inline_or_highlight/1` clause (plain inline render) handles it.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/bradhanks/perfect_paper && export PATH="/opt/homebrew/bin:$PATH"; mix test test/perfect_paper_web/components/document_components_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/bradhanks/perfect_paper
mix format lib/perfect_paper_web/components/document_components.ex test/perfect_paper_web/components/document_components_test.exs
git add lib/perfect_paper_web/components/document_components.ex test/perfect_paper_web/components/document_components_test.exs
git commit -m "refactor(web): render canonical ids from attrs + block-safe unknown-node fallback"
```

---

## Task B6: delete the duplicate engine; full suite

**Files:**
- Delete: `/Users/bradhanks/perfect_paper/lib/perfect_paper/documents/importer/pandoc.ex`
- Delete: `/Users/bradhanks/perfect_paper/lib/perfect_paper/documents/canonical.ex`
- Delete: their test files if any (`test/perfect_paper/documents/canonical_test.exs`, `.../importer/pandoc_test.exs`)

- [ ] **Step 1: Grep for any remaining references**

```bash
cd /Users/bradhanks/perfect_paper
grep -rn "Documents.Canonical\|Importer.Pandoc\|Documents\.Importer\.Pandoc" lib test config
```
Expected: no hits in `lib/`/`config/` (only this plan / docs). Fix any stragglers to use `Canonical.*` / `Importer.Panpipe`.

- [ ] **Step 2: Delete the modules and their tests**

```bash
cd /Users/bradhanks/perfect_paper
git rm lib/perfect_paper/documents/importer/pandoc.ex lib/perfect_paper/documents/canonical.ex
git rm -f test/perfect_paper/documents/canonical_test.exs 2>/dev/null || true
```

- [ ] **Step 3: Compile + full suite**

```bash
export PATH="/opt/homebrew/bin:$PATH"
mix compile --warnings-as-errors
mix test
```
Expected: compiles with no warnings about undefined `Documents.Canonical`/`Importer.Pandoc`; full suite green. Fix any fallout (most likely a lingering reference or a test that built top-level-`id` fixtures — update those fixtures to `attrs["id"]`).

- [ ] **Step 4: Commit**

```bash
cd /Users/bradhanks/perfect_paper
git add -A
git commit -m "refactor(documents): delete in-repo canonical engine; consume panpipe"
```

---

## Final verification (perfect_paper)

- [ ] `mix test` — green.
- [ ] `mix format --check-formatted` — clean.
- [ ] `mix compile --warnings-as-errors` — no warnings.
- [ ] `grep -rn "Documents.Canonical\|Importer.Pandoc" lib config` — no production references.

---

## Spec coverage self-check

| Spec requirement | Task |
|---|---|
| panpipe `Canonical.Text` UTF-16 helpers (from,to; emoji-safe) | A1 |
| panpipe `import_document/2` → map + meta | A2 |
| panpipe map-based `validate/1` | A2 |
| Tag + push fork; CI/visibility note | A3 |
| git dependency in perfect_paper | B1 |
| Importer config kept; default → Panpipe; Stub in test | B1 |
| `Importer.Panpipe` adapter | B2 |
| Repoint validation (contract change) | B3 |
| Repoint highlight + UTF-16 + attrs id | B4 |
| Renderer attrs id + safe block fallback (watch-out #1) | B5 |
| Delete duplicate engine | B6 |
| Demo wiring (out of scope) | — (separate plan) |
| First-class table/image rendering (out of scope) | — (generic block fallback only) |
