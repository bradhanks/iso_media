defmodule PerfectPaper.Billing.SeatTrackerServer do
  @moduledoc """
  Subscribes to `member.provisioned` and `member.reactivated` (SCIM / Spec 3b)
  and raises the org's active-contract `peak_seats_used` high-water mark.
  Decoupled: `Organizations` just announces activations via `Events.emit/2`.
  Errors are logged, never raised, so one bad event can't take the server down.
  """
  use GenServer
  require Logger
  alias PerfectPaper.{Billing, Events}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Events.subscribe(:"member.provisioned")
    Events.subscribe(:"member.reactivated")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:event, %Events.Event{} = event}, state) do
    try do
      Billing.bump_peak_seats_for_event(event)
    rescue
      error ->
        Logger.error("SeatTrackerServer failed on #{inspect(event.type)}: #{inspect(error)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
