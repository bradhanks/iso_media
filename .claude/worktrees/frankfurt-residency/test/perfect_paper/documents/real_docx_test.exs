defmodule PerfectPaper.Documents.RealDocxTest do
  @moduledoc """
  Real-world docx regression. Every fixture in test/support/fixtures/docx_files/
  is an actual uploaded document (legal motion, academic manuscripts, an RCT
  protocol, a technical plan). Each must run the full path the workspace uses —
  import via the configured Panpipe adapter, schema-validate, and render to HTML —
  without failing.

  These previously exposed two production bugs: empty table cells failing
  validation (killing the import) and empty-content nodes crashing the renderer.

  Tagged :pandoc (shells out to the pandoc binary), excluded from the default
  suite — run with `mix test --include pandoc`.
  """
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaperWeb.DocumentComponents

  alias PerfectPaper.Documents.Importer.Panpipe

  @dir "test/support/fixtures/docx_files"

  @tag :pandoc
  test "every real-world docx fixture imports, validates, and renders" do
    files = Path.wildcard(Path.join(@dir, "*.docx"))
    assert files != [], "no docx fixtures found in #{@dir}"

    for path <- files do
      base = Path.basename(path)
      bytes = File.read!(path)

      assert {:ok, %{doc: doc, meta: meta}} = Panpipe.import(bytes, source_format: "docx"),
             "import failed for #{base}"

      assert :ok == Canonical.validate(doc), "validation failed for #{base}"

      assert is_integer(meta["word_count"]) and meta["word_count"] > 0,
             "expected a word count for #{base}"

      html = render_component(&render_tree/1, doc: doc, active_anchor: nil)
      assert is_binary(html) and byte_size(html) > 0, "empty render for #{base}"
    end
  end
end
