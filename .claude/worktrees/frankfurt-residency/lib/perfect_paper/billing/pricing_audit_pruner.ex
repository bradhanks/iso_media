defmodule PerfectPaper.Billing.PricingAuditPruner do
  @moduledoc """
  Oban worker that anonymizes PricingAudit rows older than 180 days.
  Runs at 03:00 UTC daily on the :maintenance queue.
  Batches updates (1000 rows at a time) to avoid long-running transactions.
  """
  use Oban.Worker, queue: :maintenance

  import Ecto.Query
  alias PerfectPaper.Repo
  alias PerfectPaper.Billing.PricingAudit

  @cutoff_days 180
  @batch_size 1000

  @doc "Anonymize all PricingAudit rows older than 180 days by clearing user_id and account_country_history."
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@cutoff_days, :day)
    anonymize_batched(cutoff)
    :ok
  end

  defp anonymize_batched(cutoff) do
    ids_subquery =
      from(p in PricingAudit,
        where: p.inserted_at < ^cutoff and not is_nil(p.user_id),
        limit: @batch_size,
        select: p.id
      )

    {count, _} =
      Repo.update_all(
        from(p in PricingAudit, where: p.id in subquery(ids_subquery)),
        set: [user_id: nil, account_country_history: []]
      )

    if count == @batch_size, do: anonymize_batched(cutoff)
  end
end
