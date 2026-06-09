defmodule PerfectPaperWeb.DocumentComponents do
  @moduledoc """
  Renders the canonical document SSoT as professional reading HEEx.

  Walks the AST; each block carries a discrete `id="node-<stable id>"` (the id
  lives in `attrs["id"]`). Heading/code-block nodes may also carry a
  human-meaningful `attrs["source_id"]` (the original document slug); a hidden
  in-place `<.source_anchor>` exposes it so internal cross-references
  (`href="#slug"`) resolve, without colliding with the stable `node-<id>`. For
  the active comment's node, the flattened text is split at the UTF-16
  `[from, to)` range (via `Documents.highlight_segments/2`) and the hit wrapped
  in `<mark>`. Unknown block types fall back to a generic block container that
  recurses their children (never an inline `<p>`, which would drop block
  content). All text is HTML-escaped.
  """
  use PerfectPaperWeb, :html

  alias PerfectPaper.Documents

  attr :doc, :map, required: true
  attr :active_anchor, :map, default: nil

  def render_tree(assigns) do
    ~H"""
    <article class="prose prose-sm max-w-none font-serif">
      <.block :for={n <- @doc["content"]} node={n} active_anchor={@active_anchor} />
    </article>
    """
  end

  attr :node, :map, required: true
  attr :active_anchor, :map, default: nil

  defp block(%{node: %{"type" => "heading"}} = assigns) do
    ~H"""
    <.heading node={@node} active_anchor={@active_anchor} />
    """
  end

  defp block(%{node: %{"type" => "paragraph"}} = assigns) do
    ~H"""
    <p id={"node-#{@node["attrs"]["id"]}"}>
      <.inline_or_highlight node={@node} active_anchor={@active_anchor} />
    </p>
    """
  end

  defp block(%{node: %{"type" => "blockquote"}} = assigns) do
    ~H"""
    <blockquote id={"node-#{@node["attrs"]["id"]}"}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </blockquote>
    """
  end

  defp block(%{node: %{"type" => "bullet_list"}} = assigns) do
    ~H"""
    <ul id={"node-#{@node["attrs"]["id"]}"}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </ul>
    """
  end

  defp block(%{node: %{"type" => "ordered_list"}} = assigns) do
    ~H"""
    <ol id={"node-#{@node["attrs"]["id"]}"}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </ol>
    """
  end

  defp block(%{node: %{"type" => "list_item"}} = assigns) do
    ~H"""
    <li id={"node-#{@node["attrs"]["id"]}"}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </li>
    """
  end

  defp block(%{node: %{"type" => "code_block"}} = assigns) do
    ~H"""
    <pre id={"node-#{@node["attrs"]["id"]}"}><.source_anchor node={@node} /><code>{Canonical.flatten_text(@node)}</code></pre>
    """
  end

  defp block(%{node: %{"type" => "horizontal_rule"}} = assigns) do
    ~H"""
    <hr id={"node-#{@node["attrs"]["id"]}"} />
    """
  end

  defp block(%{node: %{"type" => "table"}} = assigns) do
    ~H"""
    <table id={"node-#{@node["attrs"]["id"]}"}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </table>
    """
  end

  defp block(%{node: %{"type" => "table_caption"}} = assigns) do
    ~H"""
    <caption id={"node-#{@node["attrs"]["id"]}"}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </caption>
    """
  end

  defp block(%{node: %{"type" => "table_row"}} = assigns) do
    ~H"""
    <tr id={"node-#{@node["attrs"]["id"]}"}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </tr>
    """
  end

  defp block(%{node: %{"type" => "table_header"}} = assigns) do
    ~H"""
    <th id={"node-#{@node["attrs"]["id"]}"}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </th>
    """
  end

  defp block(%{node: %{"type" => "table_cell"}} = assigns) do
    ~H"""
    <td id={"node-#{@node["attrs"]["id"]}"}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </td>
    """
  end

  # Unknown block-ish node (table/table_row/cell/def_list/etc.): render a generic
  # container and recurse its children as BLOCKS. Never force block children into
  # an inline `<p>` (that would silently drop them).
  defp block(%{node: %{"content" => content}} = assigns) when is_list(content) do
    ~H"""
    <div id={"node-#{@node["attrs"]["id"]}"} data-node-type={@node["type"]}>
      <.block :for={c <- content(@node)} node={c} active_anchor={@active_anchor} />
    </div>
    """
  end

  # Leaf/inline-ish unknown node.
  defp block(assigns) do
    ~H"""
    <p id={"node-#{@node["attrs"]["id"]}"}>
      <.inline_or_highlight node={@node} active_anchor={@active_anchor} />
    </p>
    """
  end

  attr :node, :map, required: true
  attr :active_anchor, :map, default: nil

  defp heading(%{node: %{"attrs" => %{"level" => 1}}} = assigns),
    do: ~H|<h1 id={"node-#{@node["attrs"]["id"]}"}><.source_anchor node={@node} />
  <.inline_or_highlight node={@node} active_anchor={@active_anchor} /></h1>|

  defp heading(%{node: %{"attrs" => %{"level" => 2}}} = assigns),
    do: ~H|<h2 id={"node-#{@node["attrs"]["id"]}"}><.source_anchor node={@node} />
  <.inline_or_highlight node={@node} active_anchor={@active_anchor} /></h2>|

  defp heading(assigns),
    do: ~H|<h3 id={"node-#{@node["attrs"]["id"]}"}><.source_anchor node={@node} />
  <.inline_or_highlight node={@node} active_anchor={@active_anchor} /></h3>|

  attr :node, :map, required: true

  # An invisible, in-place anchor carrying the source document's identifier
  # (e.g. `# Intro {#intro}`), so internal cross-references (`href="#intro"`)
  # resolve. The element keeps its stable `id="node-<id>"`; this is a separate
  # target, so no id collision. Only heading/code_block nodes carry source_id.
  defp source_anchor(%{node: %{"attrs" => %{"source_id" => sid}}} = assigns)
       when is_binary(sid) do
    ~H|<a id={@node["attrs"]["source_id"]} class="sr-only" aria-hidden="true"></a>|
  end

  defp source_anchor(assigns), do: ~H||

  attr :node, :map, required: true
  attr :active_anchor, :map, default: nil

  # Active node → highlight segments (marks dropped within the highlighted node,
  # by design). Inactive node → inline content with marks. Match the node's
  # attrs id against the anchor's node_id in the pattern, then compare in the
  # guard (map access isn't allowed inside guards).
  defp inline_or_highlight(
         %{node: %{"attrs" => %{"id" => node_id}}, active_anchor: %{node_id: anchor_id}} = assigns
       )
       when node_id == anchor_id and not is_nil(anchor_id) do
    assigns =
      assign(
        assigns,
        :segments,
        Documents.highlight_segments(assigns.node, assigns.active_anchor)
      )

    ~H"""
    <%= for seg <- @segments do %>
      <mark :if={seg.highlight} class="rounded-sm bg-accent/20">{seg.text}</mark><span :if={
        !seg.highlight
      }>{seg.text}</span>
    <% end %>
    """
  end

  defp inline_or_highlight(assigns) do
    ~H"""
    <.inline :for={c <- content(@node)} text={c} />
    """
  end

  # Canonical nodes may carry no children — an empty paragraph/heading or a
  # list with no items arrives as a missing or nil "content". Normalise to a
  # list so the `:for` comprehensions never iterate a nil (which would raise
  # Enumerable-not-implemented for Atom). List.wrap also tolerates a stray
  # single child node.
  defp content(node), do: List.wrap(node["content"])

  attr :text, :map, required: true

  defp inline(%{text: %{"type" => "text", "marks" => marks}} = assigns) do
    assigns = assign(assigns, :marks, Enum.map(marks, & &1["type"]))
    wrap_marks(assigns)
  end

  defp inline(%{text: %{"type" => "text"}} = assigns), do: ~H|{@text["text"]}|

  defp inline(%{text: %{"type" => "image"}} = assigns),
    do:
      ~H|<img src={@text["attrs"]["src"]} alt={@text["attrs"]["alt"]} title={@text["attrs"]["title"]} />|

  defp inline(%{text: %{"type" => "hard_break"}} = assigns), do: ~H|<br />|

  defp inline(assigns), do: ~H||

  defp wrap_marks(%{marks: marks} = assigns) do
    cond do
      "code" in marks -> ~H|<code>{@text["text"]}</code>|
      "strong" in marks and "em" in marks -> ~H|<strong><em>{@text["text"]}</em></strong>|
      "strong" in marks -> ~H|<strong>{@text["text"]}</strong>|
      "em" in marks -> ~H|<em>{@text["text"]}</em>|
      "link" in marks -> ~H|<a href={link_href(@text)}>{@text["text"]}</a>|
      true -> ~H|{@text["text"]}|
    end
  end

  defp link_href(%{"marks" => marks}) do
    case Enum.find(marks, &(&1["type"] == "link")) do
      %{"attrs" => %{"href" => href}} -> href
      _ -> "#"
    end
  end
end
