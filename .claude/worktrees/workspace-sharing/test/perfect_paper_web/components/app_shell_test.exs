defmodule PerfectPaperWeb.AppShellTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest
  import PerfectPaperWeb.AppShell

  describe "app/1 sidebar" do
    test "renders the brand wordmark, logo, sections, and nav items" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.app flash={%{}} active={:new}>Body</.app>
        """)

      assert html =~ "Perfect"
      assert html =~ "Paper"
      assert html =~ "/images/icon-mulberry.svg"
      assert html =~ "Reviews"
      assert html =~ "Account"
      assert html =~ "New review"
      assert html =~ "menu-active"
    end
  end

  describe "app/1 header" do
    test "renders the centered title and body, without a menu toggle" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.app flash={%{}} title="My Manuscript">Body content</.app>
        """)

      assert html =~ "My Manuscript"
      assert html =~ "Body content"
      refute html =~ "MENU"
    end

    test "title_block slot overrides the plain title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.app flash={%{}} title="PLAIN TITLE">
          <:title_block><span>CUSTOM TITLE BLOCK</span></:title_block>
          Body
        </.app>
        """)

      assert html =~ "CUSTOM TITLE BLOCK"
      refute html =~ "PLAIN TITLE"
    end

    test "sidebar and mobile dock hide in immersive (full-screen) mode" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.app flash={%{}} active={:new}>Body</.app>
        """)

      # the immersive toggle flips data-immersive on #app-shell; these classes hide chrome
      assert html =~ "group-data-[immersive=true]/shell:hidden"
    end

    test "renders header actions slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.app flash={%{}} title="Doc">
          <:actions><button>Custom action</button></:actions>
          Body
        </.app>
        """)

      assert html =~ "Custom action"
    end
  end

  describe "app/1 collapse rail" do
    test "the collapse toggle is hook-driven by id, not a per-render JS attribute toggle" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.app flash={%{}} active={:new}>Body</.app>
        """)

      # The SidebarDrawer hook owns + persists the rail state via this id, so
      # navigating (clicking a nav icon) no longer re-expands the rail.
      assert html =~ ~s(id="app-collapse-toggle")
      refute html =~ "toggle_attr"
    end

    test "the toggle divider sits at 50% when open and 25% when collapsed" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.app flash={%{}} active={:new}>Body</.app>
        """)

      # 50% divider (x=12) shown when open, 25% (x=7.5) when collapsed.
      assert html =~ ~s(d="M12 4v16")
      assert html =~ ~s(d="M7.5 4v16")
      refute html =~ ~s(d="M9 4v16")
    end

    test "section titles keep their vertical space when collapsed (invisible, not hidden)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.app flash={%{}} active={:new}>Body</.app>
        """)

      # Invisible (not display:none) so the icons below keep the same spacing.
      assert html =~ "menu-title group-data-[collapsed=true]/shell:invisible"
    end
  end

  describe "workspace/1" do
    test "renders document and feedback panes plus optional chat" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.workspace>
          <:document>DOC PANE</:document>
          <:feedback>FEEDBACK PANE</:feedback>
          <:chat>CHAT DRAWER</:chat>
        </.workspace>
        """)

      assert html =~ "DOC PANE"
      assert html =~ "FEEDBACK PANE"
      assert html =~ "CHAT DRAWER"
    end

    test "omits chat section when chat slot absent" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.workspace>
          <:document>DOC</:document>
          <:feedback>FB</:feedback>
        </.workspace>
        """)

      assert html =~ "DOC"
      assert html =~ "FB"
      refute html =~ "border-l"
    end

    test "renders the chat section border only when chat present" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.workspace>
          <:document>DOC</:document>
          <:feedback>FB</:feedback>
          <:chat>CHAT</:chat>
        </.workspace>
        """)

      assert html =~ "border-l"
    end

    test "wires the draggable pane resizer (PaneResize hook + handle + doc-basis var)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.workspace>
          <:document>DOC</:document>
          <:feedback>FB</:feedback>
        </.workspace>
        """)

      assert html =~ ~s(phx-hook="PaneResize")
      assert html =~ "data-resize-handle"
      assert html =~ "var(--doc-basis"
      assert html =~ ~s(role="separator")
    end
  end

  describe "pane headers" do
    test "doc_pane_header renders the DOCUMENT label and actions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.doc_pane_header>
          <:actions><button>Download</button></:actions>
        </.doc_pane_header>
        """)

      assert html =~ "DOCUMENT"
      assert html =~ "Download"
    end

    test "feedback_pane_header renders the FEEDBACK label" do
      html = render_component(&feedback_pane_header/1, [])
      assert html =~ "FEEDBACK"
    end
  end

  describe "chat_panel/1" do
    test "renders title, messages, and a static input row" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.chat_panel title="Ask about this review" placeholder="Type here">
          <:messages>TRANSCRIPT</:messages>
        </.chat_panel>
        """)

      assert html =~ "Ask about this review"
      assert html =~ "TRANSCRIPT"
      assert html =~ "Type here"
      assert html =~ "<textarea"
    end
  end
end
