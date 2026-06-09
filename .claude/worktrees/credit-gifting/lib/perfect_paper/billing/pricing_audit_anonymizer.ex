defmodule PerfectPaper.Billing.PricingAuditAnonymizer do
  @moduledoc """
  Scheduled retention sweep that anonymizes pricing-decision rows older than the
  retention window (default 180 days).

  Runs on the `:maintenance` queue, scheduled daily by `Oban.Plugins.Cron`. The
  actual work is a **batched** anonymization in `Billing` (keyset-free but
  bounded: each pass updates a `LIMIT`ed set and excludes already-anonymized
  rows, looping until drained) so the append-only log is never rewritten by one
  unbounded statement. `PricingAudit` is PII + a movement profile; without this
  job (and the `Cron` plugin that fires it) that data would grow unbounded.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias PerfectPaper.Billing

  # Retention window in days (anonymize once a row is older than this).
  @retention_days 180

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@retention_days * 86_400, :second)
      |> DateTime.truncate(:second)

    {:ok, _count} = Billing.anonymize_pricing_audits_before(cutoff)
    :ok
  end

  @doc "The retention window in days."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days
end
