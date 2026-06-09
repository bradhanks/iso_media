defmodule PerfectPaperWeb.NewLiveTest do
  use PerfectPaperWeb.ConnCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.{Credits, Repo, Workspaces}
  alias PerfectPaper.Documents.Document

  @docx_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  describe "New review" do
    test "renders the upload form", %{conn: conn} do
      user = user_fixture()
      ws = Workspaces.personal_workspace(user)
      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/w/#{ws.id}/new")

      assert html =~ "Start a new review"
      assert html =~ "Start review"
    end

    test "redirects when not logged in", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/w/#{Ecto.UUID.generate()}/new")
      assert path =~ "/users/log-in"
    end

    test "uploading a .docx lands the review in the URL's workspace and redirects to it",
         %{conn: conn} do
      user = user_fixture()
      ws = Workspaces.personal_workspace(user)
      {:ok, _} = Credits.grant(user.id, 1, "test")
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/w/#{ws.id}/new")

      file =
        file_input(lv, "#upload-form", :manuscript, [
          %{name: "My Paper.docx", content: "fake-docx-bytes", type: @docx_type}
        ])

      render_upload(file, "My Paper.docx")
      render_submit(form(lv, "#upload-form"))

      doc = Repo.get_by!(Document, filename: "My Paper.docx")
      assert doc.status == :pending
      assert doc.source_format == "docx"

      assert_enqueued(
        worker: PerfectPaper.Documents.Conversion,
        args: %{"document_id" => doc.id}
      )

      # The review was created in the URL's workspace and we navigate into it.
      [session] = PerfectPaper.History.list_sessions(PerfectPaper.Authz.load_subject(user))
      assert session.workspace_id == ws.id

      assert {path, _flash} = assert_redirect(lv)
      assert path == "/w/#{ws.id}/review/#{session.id}"
    end

    test "out of credits: shows the message and ingests nothing", %{conn: conn} do
      user = user_fixture()
      ws = Workspaces.personal_workspace(user)
      conn = log_in_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/w/#{ws.id}/new")

      file =
        file_input(lv, "#upload-form", :manuscript, [
          %{name: "p.docx", content: "x", type: @docx_type}
        ])

      render_upload(file, "p.docx")
      html = render_submit(form(lv, "#upload-form"))

      assert html =~ "out of credits"
      assert Repo.aggregate(Document, :count) == 0
    end
  end
end
