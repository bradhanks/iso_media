defmodule PerfectPaperWeb.DocumentComponentsTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaperWeb.DocumentComponents

  @doc_tree %{
    "type" => "doc",
    "content" => [
      %{
        "type" => "heading",
        "attrs" => %{"id" => "n_h", "level" => 1},
        "content" => [%{"type" => "text", "text" => "My Title"}]
      },
      %{
        "type" => "paragraph",
        "attrs" => %{"id" => "n_p"},
        "content" => [
          %{"type" => "text", "text" => "Plain "},
          %{"type" => "text", "text" => "bold", "marks" => [%{"type" => "strong"}]}
        ]
      }
    ]
  }

  test "renders headings and paragraphs with stable node ids from attrs" do
    html = render_component(&render_tree/1, doc: @doc_tree, active_anchor: nil)
    assert html =~ ~s(id="node-n_h")
    assert html =~ "My Title"
    assert html =~ ~s(id="node-n_p")
    assert html =~ "<strong>bold</strong>"
  end

  test "escapes document text" do
    tree = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "paragraph",
          "attrs" => %{"id" => "n_x"},
          "content" => [%{"type" => "text", "text" => "<script>x</script>"}]
        }
      ]
    }

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

  test "renders a safe block container for unknown block types, recursing children" do
    doc = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "sidebar",
          "attrs" => %{"id" => "t1"},
          "content" => [
            %{
              "type" => "paragraph",
              "attrs" => %{"id" => "p2"},
              "content" => [%{"type" => "text", "text" => "cell"}]
            }
          ]
        }
      ]
    }

    html = render_component(&render_tree/1, doc: doc, active_anchor: nil)
    # unknown block (sidebar) renders as a generic container exposing its id...
    assert html =~ ~s(id="node-t1")
    assert html =~ ~s(data-node-type="sidebar")
    # ...and the child paragraph survives (block children were recursed, not dropped)
    assert html =~ ~s(id="node-p2")
    assert html =~ "cell"
  end

  test "emits a source_id anchor target while preserving the stable node id" do
    tree = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "heading",
          "attrs" => %{"id" => "n_h", "level" => 1, "source_id" => "intro"},
          "content" => [%{"type" => "text", "text" => "Introduction"}]
        }
      ]
    }

    html = render_component(&render_tree/1, doc: tree, active_anchor: nil)
    assert html =~ ~s(id="intro")
    assert html =~ ~s(id="node-n_h")
  end

  test "no source anchor when the node lacks source_id" do
    tree = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "heading",
          "attrs" => %{"id" => "n_h2", "level" => 1},
          "content" => [%{"type" => "text", "text" => "Plain"}]
        }
      ]
    }

    html = render_component(&render_tree/1, doc: tree, active_anchor: nil)
    assert html =~ ~s(id="node-n_h2")
    refute html =~ ~s(id="intro")
  end

  test "renders a table as semantic HTML with header and data cells" do
    cell = fn id, type, text ->
      %{
        "type" => type,
        "attrs" => %{"id" => id, "align" => "default", "rowspan" => 1, "colspan" => 1},
        "content" => [
          %{
            "type" => "paragraph",
            "attrs" => %{"id" => "p#{id}"},
            "content" => [%{"type" => "text", "text" => text}]
          }
        ]
      }
    end

    doc = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "table",
          "attrs" => %{"id" => "t1", "colspec" => []},
          "content" => [
            %{
              "type" => "table_row",
              "attrs" => %{"id" => "r1"},
              "content" => [cell.("h1", "table_header", "Head")]
            },
            %{
              "type" => "table_row",
              "attrs" => %{"id" => "r2"},
              "content" => [cell.("c1", "table_cell", "Data")]
            }
          ]
        }
      ]
    }

    html = render_component(&render_tree/1, doc: doc, active_anchor: nil)
    assert html =~ "<table"
    assert html =~ "<tr"
    assert html =~ "<th"
    assert html =~ "Head"
    assert html =~ "<td"
    assert html =~ "Data"
  end

  test "tolerates nodes with missing or nil content without crashing" do
    doc = %{
      "type" => "doc",
      "content" => [
        # paragraph with no "content" key at all (e.g. an empty line)
        %{"type" => "paragraph", "attrs" => %{"id" => "empty_p"}},
        # heading with explicit nil content
        %{"type" => "heading", "attrs" => %{"id" => "empty_h", "level" => 2}, "content" => nil},
        # list whose content is nil
        %{"type" => "bullet_list", "attrs" => %{"id" => "empty_ul"}, "content" => nil},
        # a normal paragraph still renders alongside the empty ones
        %{
          "type" => "paragraph",
          "attrs" => %{"id" => "real_p"},
          "content" => [%{"type" => "text", "text" => "survives"}]
        }
      ]
    }

    html = render_component(&render_tree/1, doc: doc, active_anchor: nil)
    assert html =~ ~s(id="node-empty_p")
    assert html =~ ~s(id="node-empty_ul")
    assert html =~ ~s(id="node-real_p")
    assert html =~ "survives"
  end

  test "renders an inline image" do
    doc = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "paragraph",
          "attrs" => %{"id" => "p"},
          "content" => [
            %{
              "type" => "image",
              "attrs" => %{"id" => "i", "src" => "pic.png", "alt" => "a pic", "title" => ""}
            }
          ]
        }
      ]
    }

    html = render_component(&render_tree/1, doc: doc, active_anchor: nil)
    assert html =~ "<img"
    assert html =~ ~s(src="pic.png")
    assert html =~ ~s(alt="a pic")
  end
end
