defmodule PerfectPaper.Teams.NotifyWorker do
  @moduledoc """
  Oban worker that sends one proactive Teams card to a linked user.

  Queue `:teams_notifier` (concurrency 5) keeps Bot Connector request volume low
  and reduces 429 pressure. Exponential backoff with per-attempt jitter smooths
  retries without producing thundering-herd re-spikes.
  """
  # `unique` on event_id dedups a re-emitted / duplicate ENQUEUE of the same event.
  # TODO(teams): the crash-after-send window (a single job retried after its Bot
  # Connector POST succeeded but before Oban marks it complete) can still
  # re-send; closing it requires a delivered-log / idempotency key honored by the
  # real Bot Connector adapter (currently a stub) — track with that adapter.
  use Oban.Worker,
    queue: :teams_notifier,
    max_attempts: 5,
    unique: [
      keys: [:event_id],
      states: ~w(available scheduled executing retryable suspended completed)a
    ]

  alias PerfectPaper.Teams

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "event_type" => event_type, "title" => title}
      }) do
    Teams.notify(user_id, String.to_existing_atom(event_type), %{title: title})
    :ok
  end

  @doc """
  Exponential backoff with jitter: `2^attempt + rand(1, 2^attempt)` seconds.
  Keeps concurrent retry spikes spread out when Bot Connector rate-limits.
  """
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    base = :math.pow(2, attempt) |> trunc()
    base + :rand.uniform(base)
  end
end
