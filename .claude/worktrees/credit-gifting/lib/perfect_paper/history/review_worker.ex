defmodule PerfectPaper.History.ReviewWorker do
  @moduledoc """
  Runs the AI review for a session, async, on the canonical document text.
  Chained after document conversion. Idempotent: `unique` on `session_id` so a
  Conversion retry can't enqueue a duplicate (which would mean duplicate paid
  LLM calls).
  """
  use Oban.Worker,
    queue: :reviews,
    unique: [
      keys: [:session_id],
      states: ~w(available scheduled executing retryable suspended completed cancelled)a
    ]

  alias PerfectPaper.{Documents, History, Repo}
  alias PerfectPaper.History.Session

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:cancel, term()} | {:error, term()}
  def perform(%Oban.Job{args: %{"session_id" => session_id}}) do
    session = Repo.get!(Session, session_id)

    with %Session{document_id: doc_id} when not is_nil(doc_id) <- session,
         %Documents.Document{} = document <- Documents.get_document(doc_id),
         text when is_binary(text) <- Documents.canonical_text(document),
         {:ok, _reviewed} <- History.process_session(session, text) do
      :ok
    else
      nil -> {:cancel, :document_missing}
      %Session{document_id: nil} -> {:cancel, :no_document}
      text when is_nil(text) -> {:cancel, :not_converted}
      {:error, :no_credits} -> {:cancel, :no_credits}
      {:error, reason} -> {:error, reason}
    end
  end
end
