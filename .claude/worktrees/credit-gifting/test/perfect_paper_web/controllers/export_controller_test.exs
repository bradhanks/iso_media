defmodule PerfectPaperWeb.ExportControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.{Documents, History, Repo}
  alias PerfectPaper.Documents.Document

  defp converted_session(user) do
    {:ok, document} =
      Documents.store_and_register(user, "bytes", %{
        filename: "my_paper.docx",
        source_format: "docx"
      })

    {:ok, document} =
      document
      |> Document.canonical_changeset(%{
        canonical_doc: %{
          "type" => "doc",
          "content" => [
            %{
              "type" => "heading",
              "attrs" => %{"id" => "h", "level" => 1},
              "content" => [%{"type" => "text", "text" => "Exported Heading"}]
            }
          ]
        },
        status: :converted
      })
      |> Repo.update()

    workspace = PerfectPaper.Workspaces.personal_workspace(user)

    {:ok, session} =
      History.begin_session(%{
        user_id: user.id,
        title: "my_paper",
        document_id: document.id,
        workspace_id: workspace.id
      })

    session
  end

  test "a stranger cannot download someone else's review", %{conn: conn} do
    owner = user_fixture()
    stranger = user_fixture()
    session = converted_session(owner)

    conn =
      get(
        log_in_user(conn, stranger),
        ~p"/w/#{session.workspace_id}/review/#{session.id}/export/markdown"
      )

    assert response(conn, 404)
  end

  test "an unsupported format is rejected", %{conn: conn} do
    user = user_fixture()
    session = converted_session(user)

    conn =
      get(log_in_user(conn, user), ~p"/w/#{session.workspace_id}/review/#{session.id}/export/pdf")

    assert response(conn, 400)
  end

  @tag :pandoc
  test "the owner downloads Markdown named with _PP", %{conn: conn} do
    user = user_fixture()
    session = converted_session(user)

    conn =
      get(
        log_in_user(conn, user),
        ~p"/w/#{session.workspace_id}/review/#{session.id}/export/markdown"
      )

    assert response(conn, 200) =~ "Exported Heading"

    assert {"content-disposition", disposition} =
             Enum.find(conn.resp_headers, &(elem(&1, 0) == "content-disposition"))

    assert disposition =~ "my_paper_PP.md"
  end
end
