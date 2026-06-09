defmodule PerfectPaper.History.ReviewWorkerTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  alias PerfectPaper.{Credits, Documents, History, Repo}
  alias PerfectPaper.Documents.Document
  alias PerfectPaper.History.{ReviewWorker, Session}

  import PerfectPaper.AccountsFixtures

  defp converted_doc_and_session(user) do
    {:ok, doc} =
      Documents.store_and_register(user, "bytes", %{filename: "p.docx", source_format: "docx"})

    tree = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "paragraph",
          "id" => "n_1",
          "content" => [%{"type" => "text", "text" => "The manuscript body."}]
        }
      ]
    }

    {:ok, doc} =
      doc
      |> Document.canonical_changeset(%{canonical_doc: tree, status: :converted})
      |> Repo.update()

    {:ok, session} = History.begin_session(%{user_id: user.id, title: "P", document_id: doc.id})
    {doc, session}
  end

  test "runs the review on canonical text and completes the session" do
    user = user_fixture()
    Credits.grant(user.id, 1, "test")
    {_doc, session} = converted_doc_and_session(user)

    assert :ok = perform_job(ReviewWorker, %{"session_id" => session.id})

    reloaded = Repo.get!(Session, session.id) |> Repo.preload(:comments)
    assert reloaded.processing_status == :complete
    assert length(reloaded.comments) > 0
  end

  test "is unique per session — a duplicate enqueue is deduped" do
    user = user_fixture()
    {_doc, session} = converted_doc_and_session(user)

    assert {:ok, _} = History.enqueue_review(session)
    assert {:ok, _} = History.enqueue_review(session)
    assert_enqueued(worker: ReviewWorker, args: %{"session_id" => session.id})
    assert length(all_enqueued(worker: ReviewWorker)) == 1
  end
end
