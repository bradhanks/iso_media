defmodule PerfectPaper.Credits.LowBalanceUpsellWorker do
  @moduledoc """
  Delivers the localized low-credit upsell email. Enqueued by
  `Credits.LowBalanceServer` on a `:"credits.low"` event. Unique on the emit's
  `crossing_id` so an Oban retry can't double-send, while two genuine crossings
  (each a fresh `crossing_id`) still each send.
  """
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [keys: [:crossing_id], period: 60 * 60, states: Oban.Job.states()]

  alias PerfectPaper.{Accounts, Credits}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "balance" => balance, "threshold" => threshold}
      }) do
    case Accounts.get_user(user_id) do
      nil -> :ok
      %{email: nil} -> :ok
      user -> Credits.deliver_low_balance_upsell(user, balance, threshold) |> normalize()
    end
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, :no_email}), do: :ok
  defp normalize({:error, _} = err), do: err
end
