defmodule PerfectPaperWeb.ReadingRoomLiveTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.{Documents, History, Repo, Workspaces}
  alias PerfectPaper.Documents.Document

  defp ws(user), do: Workspaces.personal_workspace(user)

  test "renders the linked document's canonical body", %{conn: conn} do
    user = user_fixture()
    workspace = ws(user)

    {:ok, document} =
      Documents.store_and_register(user, "# Linked\n", %{
        filename: "l.md",
        source_format: "markdown"
      })

    {:ok, _document} =
      document
      |> Document.canonical_changeset(%{
        canonical_doc: %{
          "type" => "doc",
          "content" => [
            %{
              "type" => "heading",
              "attrs" => %{"id" => "n_lh", "level" => 1},
              "content" => [%{"type" => "text", "text" => "Linked Manuscript"}]
            }
          ]
        },
        status: :converted
      })
      |> Repo.update()

    {:ok, session} =
      History.begin_session(%{
        user_id: user.id,
        title: "Linked Manuscript",
        document_id: document.id,
        workspace_id: workspace.id
      })

    {:ok, _lv, html} =
      live(log_in_user(conn, user), ~p"/w/#{workspace.id}/review/#{session.id}")

    assert html =~ "Linked Manuscript"
    assert html =~ ~s(id="node-n_lh")
  end

  test "shows Converting… for a pending document, then renders the body on the scoped event",
       %{conn: conn} do
    user = user_fixture()
    workspace = ws(user)

    {:ok, document} =
      Documents.store_and_register(user, "bytes", %{filename: "p.docx", source_format: "docx"})

    {:ok, document} = Repo.update(Document.status_changeset(document, :pending))

    {:ok, session} =
      History.begin_session(%{
        user_id: user.id,
        title: "P",
        document_id: document.id,
        workspace_id: workspace.id
      })

    {:ok, lv, html} =
      live(log_in_user(conn, user), ~p"/w/#{workspace.id}/review/#{session.id}")

    assert html =~ "Converting"

    tree = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "heading",
          "attrs" => %{"id" => "n_h", "level" => 1},
          "content" => [%{"type" => "text", "text" => "Now Visible"}]
        }
      ]
    }

    {:ok, _} =
      document
      |> Document.canonical_changeset(%{canonical_doc: tree, status: :converted})
      |> Repo.update()

    Phoenix.PubSub.broadcast(
      PerfectPaper.PubSub,
      "document:#{document.id}",
      {:document_converted, document.id}
    )

    html = render(lv)
    assert html =~ ~s(id="node-n_h")
    assert html =~ "Now Visible"
  end

  test "shows the failed state on a conversion_failed event", %{conn: conn} do
    user = user_fixture()
    workspace = ws(user)

    {:ok, document} =
      Documents.register_upload(user, %{filename: "p.docx", source_format: "docx"})

    {:ok, session} =
      History.begin_session(%{
        user_id: user.id,
        title: "P",
        document_id: document.id,
        workspace_id: workspace.id
      })

    {:ok, lv, _} = live(log_in_user(conn, user), ~p"/w/#{workspace.id}/review/#{session.id}")

    Phoenix.PubSub.broadcast(
      PerfectPaper.PubSub,
      "document:#{document.id}",
      {:document_conversion_failed, document.id}
    )

    assert render(lv) =~ "process that file"
  end

  test "canonicalizes the URL when the workspace doesn't match the review", %{conn: conn} do
    user = user_fixture()
    real = ws(user)
    {:ok, other} = Workspaces.create_workspace(user, %{name: "Other"})

    {:ok, document} =
      Documents.store_and_register(user, "# X\n", %{filename: "x.md", source_format: "markdown"})

    {:ok, session} =
      History.begin_session(%{
        user_id: user.id,
        title: "X",
        document_id: document.id,
        workspace_id: real.id
      })

    # Hit it under the WRONG workspace → expect a redirect to the canonical URL.
    assert {:error, {:live_redirect, %{to: to}}} =
             live(log_in_user(conn, user), ~p"/w/#{other.id}/review/#{session.id}")

    assert to == "/w/#{real.id}/review/#{session.id}"
  end

  test "a session with no workspace mounts under any /w/ URL without redirect", %{conn: conn} do
    user = user_fixture()
    workspace = ws(user)

    {:ok, document} =
      Documents.store_and_register(user, "# Z\n", %{filename: "z.md", source_format: "markdown"})

    # No workspace_id (e.g. an enterprise/group-owned session) — must not redirect.
    {:ok, session} =
      History.begin_session(%{user_id: user.id, title: "No Workspace", document_id: document.id})

    assert session.workspace_id == nil

    {:ok, _lv, html} =
      live(log_in_user(conn, user), ~p"/w/#{workspace.id}/review/#{session.id}")

    assert html =~ "No Workspace"
  end

  test "clicking a comment highlights its anchored passage in the document", %{conn: conn} do
    user = user_fixture()
    workspace = ws(user)

    {:ok, document} =
      Documents.store_and_register(user, "x", %{filename: "h.md", source_format: "markdown"})

    {:ok, _} =
      document
      |> Document.canonical_changeset(%{
        canonical_doc: %{
          "type" => "doc",
          "content" => [
            %{
              "type" => "paragraph",
              "attrs" => %{"id" => "para-x"},
              "content" => [%{"type" => "text", "text" => "Please highlight me here."}]
            }
          ]
        },
        status: :converted
      })
      |> Repo.update()

    {:ok, session} =
      History.begin_session(%{
        user_id: user.id,
        title: "Doc",
        document_id: document.id,
        workspace_id: workspace.id
      })

    {:ok, comment} =
      %PerfectPaper.History.Comment{session_id: session.id}
      |> Ecto.Changeset.change(%{
        original_text: "highlight me",
        suggestion: "Tighten this",
        status: :open,
        position: 1,
        anchor_node_id: "para-x",
        anchor_from: 7,
        anchor_to: 19
      })
      |> Repo.insert()

    {:ok, lv, html} =
      live(log_in_user(conn, user), ~p"/w/#{workspace.id}/review/#{session.id}")

    refute html =~ "<mark"

    highlighted = render_click(lv, "select_comment", %{"id" => comment.id})
    assert highlighted =~ "<mark"
    assert highlighted =~ "highlight me"

    # Clicking again toggles the highlight off.
    refute render_click(lv, "select_comment", %{"id" => comment.id}) =~ "<mark"
  end

  test "the manuscript title is click-to-edit and renames the review", %{conn: conn} do
    user = user_fixture()
    workspace = ws(user)

    {:ok, session} =
      History.begin_session(%{
        user_id: user.id,
        title: "Original Title",
        workspace_id: workspace.id
      })

    {:ok, lv, html} = live(log_in_user(conn, user), ~p"/w/#{workspace.id}/review/#{session.id}")

    # Title shown; no edit form yet.
    assert html =~ "Original Title"
    refute html =~ ~s(name="title")

    # Click the title → the rename form appears.
    html = render_click(lv, "edit_title")
    assert html =~ ~s(name="title")

    # Submit a new title → it persists and the header updates.
    html = render_submit(lv, "rename", %{"title" => "  A Sharper Title  "})
    assert html =~ "A Sharper Title"
    assert Repo.reload!(session).title == "A Sharper Title"
  end

  test "renders the full-screen reading toggle", %{conn: conn} do
    user = user_fixture()
    workspace = ws(user)

    {:ok, session} =
      History.begin_session(%{user_id: user.id, title: "Doc", workspace_id: workspace.id})

    {:ok, _lv, html} = live(log_in_user(conn, user), ~p"/w/#{workspace.id}/review/#{session.id}")

    assert html =~ "Toggle full-screen reading"
    assert html =~ "data-immersive"
  end
end
