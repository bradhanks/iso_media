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

  # The adapter normalizes vendor error shapes into our own deterministic
  # vocabulary so Conversion.deterministic?/1 can {:cancel} corrupt uploads
  # instead of retrying them 3×. These guard against a pandoc/Exile error-shape
  # change silently breaking that classification (regressing the retry-storm bug).
  @tag :pandoc
  test "a corrupt document (pandoc abnormal exit) normalizes to :unconvertible_source" do
    corrupt = :crypto.strong_rand_bytes(2000)
    assert {:error, :unconvertible_source} = Panpipe.import(corrupt, source_format: "docx")
  end

  @tag :pandoc
  test "schema-invalid input normalizes to {:invalid_document, _}" do
    assert {:error, {:invalid_document, _violations}} =
             Panpipe.import("", source_format: "markdown")
  end
end
