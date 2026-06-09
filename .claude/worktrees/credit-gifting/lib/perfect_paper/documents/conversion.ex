defmodule PerfectPaper.Documents.Conversion do
  @moduledoc """
  Converts an uploaded document into the canonical SSoT.

  Failures are classified: DETERMINISTIC errors (bad/parse-failed input, missing
  blob, validation failure) cancel the job (`{:cancel, _}`) so Oban never retries
  them; TRANSIENT errors return `{:error, _}` for normal backoff/retry.
  """
  # `unique` on document_id prevents two concurrent jobs (e.g. an operator
  # requeuing a stalled conversion while the original is still queued) from both
  # importing and clobbering each other's canonical_doc — mirrors ReviewWorker.
  use Oban.Worker,
    queue: :documents,
    max_attempts: 3,
    unique: [keys: [:document_id], states: ~w(available scheduled executing retryable suspended)a]

  @max_import_bytes 20 * 1024 * 1024
  @import_timeout_ms :timer.seconds(60)

  alias PerfectPaper.{Documents, Events, History, Repo}
  alias PerfectPaper.Documents.Document

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()} | {:cancel, term()}
  def perform(%Oban.Job{args: %{"document_id" => id}}) do
    document = Repo.get!(Document, id)

    # Idempotent: a retry of an already-:converted doc must NOT re-import —
    # re-import mints fresh canonical node ids, overwriting the SSoT. But it MUST
    # still re-run the post-persist finalize steps (which are idempotent), so a
    # crash AFTER persisting :converted but BEFORE enqueuing reviews doesn't
    # strand the session with no review forever.
    if document.status == :converted, do: finalize(document), else: convert(document)
  end

  defp convert(%{byte_size: size} = document)
       when is_integer(size) and size > @max_import_bytes do
    {:ok, _} = Repo.update(Document.status_changeset(document, :failed))
    {:cancel, {:file_too_large, size}}
  end

  defp convert(document) do
    {:ok, _} = Repo.update(Document.status_changeset(document, :converting))

    with {:ok, content} <- Documents.read_content(document),
         {:ok, %{doc: doc, meta: meta}} <- import_with_timeout(content, document.source_format),
         :ok <- Canonical.validate(doc),
         {:ok, converted} <- persist(document, doc, meta) do
      finalize(converted)
    else
      {:error, reason} ->
        {:ok, _} = Repo.update(Document.status_changeset(document, :failed))

        Events.emit(:"document.conversion_failed", %{
          resource: %{"document_id" => document.id, "reason" => inspect(reason)}
        })

        broadcast(document.id, {:document_conversion_failed, document.id})

        if deterministic?(reason), do: {:cancel, reason}, else: {:error, reason}
    end
  end

  # Post-persist side effects, all idempotent so they can safely re-run on a
  # retry of an already-:converted doc: emit + broadcast the conversion, and
  # enqueue an (idempotent, unique-on-session_id) review per linked session.
  defp finalize(document) do
    Events.emit(:"document.converted", %{resource: %{"document_id" => document.id}})
    broadcast(document.id, {:document_converted, document.id})
    Enum.each(History.sessions_for_document(document.id), &History.enqueue_review/1)
    :ok
  end

  defp persist(document, doc, meta) do
    document
    |> Document.canonical_changeset(%{
      canonical_doc: doc,
      canonical_meta: meta,
      source_format: document.source_format,
      status: :converted
    })
    |> Repo.update()
  end

  # Deterministic = retrying cannot help. Covers the importer adapter's
  # normalized failures (`:unconvertible_source` = pandoc abnormal exit on a
  # corrupt upload; `{:invalid_document, _}` = schema-invalid input), a missing
  # blob (`:enoent`), and the Canonical.validate violation list.
  defp deterministic?(:enoent), do: true
  defp deterministic?(:unconvertible_source), do: true
  defp deterministic?({:invalid_document, _}), do: true
  defp deterministic?({:pandoc_failed, _}), do: true
  defp deterministic?(list) when is_list(list), do: true
  defp deterministic?(%Ecto.Changeset{}), do: true
  defp deterministic?(_), do: false

  defp broadcast(document_id, message),
    do: Phoenix.PubSub.broadcast(PerfectPaper.PubSub, "document:#{document_id}", message)

  defp import_with_timeout(content, source_format) do
    task = Task.async(fn -> importer().import(content, source_format: source_format) end)

    case Task.yield(task, @import_timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:import_error, reason}}
      nil -> {:error, :import_timeout}
    end
  end

  defp importer, do: Application.get_env(:perfect_paper, :document_importer)
end
