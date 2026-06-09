defmodule PerfectPaper.Credits.LowBalanceServer do
  @moduledoc """
  Reacts to `credits.low` domain events by enqueuing the localized upsell email
  as an Oban job on the `:notifications` queue. The job is deduped on the event's
  `crossing_id` so an Oban retry can't double-send. The in-app banner is
  stateless (derived from balance on each mount), so no PubSub broadcast is
  needed here.
  """
  use GenServer

  alias PerfectPaper.Events
  alias PerfectPaper.Credits.LowBalanceUpsellWorker

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    Events.subscribe(:"credits.low")
    {:ok, state}
  end

  @impl true
  def handle_info(
        {:event, %Events.Event{type: :"credits.low", actor_id: user_id, data: data}},
        state
      ) do
    args =
      %{
        user_id: user_id,
        balance: get(data, :balance),
        threshold: get(data, :threshold),
        crossing_id: get(data, :crossing_id)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    _ = args |> LowBalanceUpsellWorker.new() |> Oban.insert()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp get(data, key), do: Map.get(data, key) || Map.get(data, to_string(key))
end
