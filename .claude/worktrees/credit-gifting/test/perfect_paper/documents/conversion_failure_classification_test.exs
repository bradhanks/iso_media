defmodule PerfectPaper.Documents.ConversionFailureClassificationTest do
  @moduledoc """
  The conversion worker must CANCEL (no retry) on deterministic importer errors.
  These swap the global importer, so the module is `async: false`.

  Regression: the classifier only matched read errors and validation lists, not
  the importer adapter's normalized failure shapes (`{:invalid_document, _}` for
  schema-invalid input, `:unconvertible_source` for a pandoc abnormal exit), so
  corrupt uploads retried 3× and emitted `document.conversion_failed` 3×.
  """
  use PerfectPaper.DataCase, async: false
  use Oban.Testing, repo: PerfectPaper.Repo

  alias PerfectPaper.Documents
  alias PerfectPaper.Documents.{Conversion, Document}
  alias PerfectPaper.Repo

  import PerfectPaper.AccountsFixtures

  setup do
    prev = Application.get_env(:perfect_paper, :document_importer)

    Application.put_env(
      :perfect_paper,
      :document_importer,
      PerfectPaper.Documents.Importer.ErrorStub
    )

    on_exit(fn ->
      Application.put_env(:perfect_paper, :document_importer, prev)
      Application.delete_env(:perfect_paper, :error_stub_reason)
    end)

    :ok
  end

  defp readable_doc(user) do
    {:ok, doc} =
      Documents.store_and_register(user, "irrelevant bytes", %{
        filename: "p.md",
        source_format: "markdown"
      })

    {:ok, doc} = Repo.update(Document.status_changeset(doc, :pending))
    doc
  end

  for {reason, label} <- [
        {{:invalid_document, []}, "schema-invalid input"},
        {:unconvertible_source, "a pandoc abnormal exit"}
      ] do
    test "cancels (no retry) on #{label}" do
      user = user_fixture()
      doc = readable_doc(user)
      Application.put_env(:perfect_paper, :error_stub_reason, unquote(Macro.escape(reason)))

      assert {:cancel, _} = perform_job(Conversion, %{"document_id" => doc.id})
      assert Repo.get!(Document, doc.id).status == :failed
    end
  end
end
