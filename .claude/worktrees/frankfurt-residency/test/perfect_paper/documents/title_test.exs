defmodule PerfectPaper.Documents.TitleTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Documents.Title

  defp doc(nodes), do: %{"type" => "doc", "content" => nodes}

  defp heading(text, level \\ 1),
    do: %{
      "type" => "heading",
      "attrs" => %{"level" => level},
      "content" => [%{"type" => "text", "text" => text}]
    }

  defp para(text),
    do: %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}

  describe "derive/1" do
    test "extracts an explicit \"Title:\" line, even past a generic first heading" do
      tree =
        doc([
          heading("TITLE PAGE"),
          para("Journal: SSM – Population Health"),
          para(
            "Title: Rural-Urban Divides and Cultural Dynamics: The Effects of Rural Residence"
          ),
          para("Authors: Jane Roe")
        ])

      assert Title.derive(tree) ==
               "Rural-Urban Divides and Cultural Dynamics: The Effects of Rural Residence"
    end

    test "falls back to the first non-generic heading when there is no Title: line" do
      tree = doc([heading("ABSTRACT"), heading("A Study of Vaccine Hesitancy", 1), para("Body")])
      assert Title.derive(tree) == "A Study of Vaccine Hesitancy"
    end

    test "ignores generic front-matter headings" do
      tree = doc([heading("Title Page"), heading("Abstract"), heading("Introduction")])
      assert Title.derive(tree) == nil
    end

    test "collapses whitespace and reads across inline marks" do
      tree =
        doc([
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "Title:  "},
              %{"type" => "text", "text" => "Bold", "marks" => [%{"type" => "strong"}]},
              %{"type" => "text", "text" => "   Findings"}
            ]
          }
        ])

      assert Title.derive(tree) == "Bold Findings"
    end

    test "returns nil for empty, missing-content, or non-doc input" do
      assert Title.derive(%{"type" => "doc", "content" => []}) == nil
      assert Title.derive(%{"type" => "doc"}) == nil
      assert Title.derive(nil) == nil
      assert Title.derive("nope") == nil
    end

    test "rejects an absurdly long 'Title:' paragraph (likely a run-on body line)" do
      long = "Title: " <> String.duplicate("word ", 100)
      assert Title.derive(doc([para(long)])) == nil
    end
  end
end
