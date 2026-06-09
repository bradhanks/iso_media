defmodule PerfectPaper.Documents.ConversionTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  alias PerfectPaper.Documents
  alias PerfectPaper.Documents.{Conversion, Document}
  alias PerfectPaper.Repo

  import PerfectPaper.AccountsFixtures

  setup do
    PerfectPaper.Events.subscribe(:"document.converted")
    :ok
  end

  defp pending_doc(user) do
    {:ok, doc} =
      Documents.store_and_register(user, "irrelevant bytes", %{
        filename: "p.md",
        source_format: "markdown"
      })

    # store_and_register marks :converted; reset to :pending for the worker path.
    {:ok, doc} = Repo.update(Document.status_changeset(doc, :pending))
    doc
  end

  test "converts a pending document and emits document.converted" do
    user = user_fixture()
    doc = pending_doc(user)

    assert :ok = perform_job(Conversion, %{"document_id" => doc.id})

    reloaded = Repo.get!(Document, doc.id)
    assert reloaded.status == :converted
    assert reloaded.canonical_doc["type"] == "doc"
    assert reloaded.canonical_meta["title"] == "Stub Title"

    assert_received {:event, %{type: :"document.converted"}}
  end

  test "is idempotent: re-running on an already-:converted doc does not re-import" do
    user = user_fixture()
    doc = pending_doc(user)

    assert :ok = perform_job(Conversion, %{"document_id" => doc.id})
    converted = Repo.get!(Document, doc.id)

    # A re-import would overwrite canonical_doc with a freshly-minted tree (and
    # reset the title to the stub's "Stub Title"); stamp a valid-but-distinct
    # sentinel doc so we can prove the retry short-circuits instead of re-importing.
    sentinel = %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "paragraph",
          "id" => "n_sentinel",
          "content" => [%{"type" => "text", "text" => "SENTINEL"}]
        }
      ]
    }

    {:ok, _} =
      Repo.update(
        Document.canonical_changeset(converted, %{
          canonical_doc: sentinel,
          canonical_meta: %{"title" => "SENTINEL"},
          source_format: converted.source_format,
          status: :converted
        })
      )

    assert :ok = perform_job(Conversion, %{"document_id" => doc.id})

    again = Repo.get!(Document, doc.id)
    assert again.canonical_doc == sentinel
    assert again.canonical_meta["title"] == "SENTINEL"
    assert again.status == :converted
  end

  test "re-running on an already-:converted doc re-enqueues reviews (crash-after-persist recovery)" do
    user = user_fixture()

    # store_and_register marks the doc :converted directly, with no review ever
    # enqueued — exactly the state left when the worker crashes AFTER persisting
    # :converted but BEFORE enqueuing reviews. A retry must NOT short-circuit to
    # :ok (which would strand the session with no review forever).
    {:ok, doc} =
      Documents.store_and_register(user, "bytes", %{filename: "p.md", source_format: "markdown"})

    assert Repo.get!(Document, doc.id).status == :converted

    {:ok, session} =
      PerfectPaper.History.begin_session(%{user_id: user.id, title: "P", document_id: doc.id})

    refute_enqueued(
      worker: PerfectPaper.History.ReviewWorker,
      args: %{"session_id" => session.id}
    )

    assert :ok = perform_job(Conversion, %{"document_id" => doc.id})

    assert_enqueued(
      worker: PerfectPaper.History.ReviewWorker,
      args: %{"session_id" => session.id}
    )
  end

  test "enqueues at most one conversion job per document (Oban unique constraint)" do
    user = user_fixture()
    doc = pending_doc(user)

    {:ok, _} = Oban.insert(Conversion.new(%{document_id: doc.id}))
    {:ok, _} = Oban.insert(Conversion.new(%{document_id: doc.id}))

    assert length(all_enqueued(worker: Conversion)) == 1
  end

  test "cancels (no retry) and marks :failed on a deterministic read error" do
    user = user_fixture()

    # A storage_key that was never stored → read_content returns {:error, :enoent},
    # a deterministic error the worker must NOT retry.
    {:ok, doc} =
      Documents.register_upload(user, %{
        filename: "p.md",
        source_format: "markdown",
        storage_key: "missing-#{System.unique_integer([:positive])}"
      })

    assert {:cancel, _reason} = perform_job(Conversion, %{"document_id" => doc.id})
    assert Repo.get!(Document, doc.id).status == :failed
  end

  describe "chaining + scoped broadcast" do
    test "on success: broadcasts to document:<id> and enqueues a review for the linked session" do
      user = user_fixture()
      doc = pending_doc(user)

      {:ok, session} =
        PerfectPaper.History.begin_session(%{user_id: user.id, title: "P", document_id: doc.id})

      Phoenix.PubSub.subscribe(PerfectPaper.PubSub, "document:#{doc.id}")

      assert :ok = perform_job(Conversion, %{"document_id" => doc.id})

      assert_received {:document_converted, id} when id == doc.id

      assert_enqueued(
        worker: PerfectPaper.History.ReviewWorker,
        args: %{"session_id" => session.id}
      )
    end

    test "on deterministic failure: broadcasts conversion_failed to document:<id>" do
      user = user_fixture()

      {:ok, doc} =
        PerfectPaper.Documents.register_upload(user, %{
          filename: "p.docx",
          source_format: "docx",
          storage_key: "missing-#{System.unique_integer([:positive])}"
        })

      Phoenix.PubSub.subscribe(PerfectPaper.PubSub, "document:#{doc.id}")
      assert {:cancel, _} = perform_job(Conversion, %{"document_id" => doc.id})
      assert_received {:document_conversion_failed, id} when id == doc.id
    end
  end
end
