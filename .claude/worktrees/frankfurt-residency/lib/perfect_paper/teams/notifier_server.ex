defmodule PerfectPaper.Teams.NotifierServer do
  @moduledoc """
  Subscribes to user-facing domain events on the Events bus and enqueues a
  proactive Teams card job for each one via `Teams.enqueue_for_event/1`.

  Errors are logged and swallowed — a single bad event must not crash the server
  or prevent subsequent events from being dispatched. Mirrors the pattern
  established by `Billing.SeatTrackerServer`.
  """
  use GenServer
  require Logger
  alias PerfectPaper.{Teams, Events}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Events.subscribe(:"session.completed")
    Events.subscribe(:"comment.added")
    Events.subscribe(:"session.shared")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:event, %Events.Event{} = event}, state) do
    try do
      Teams.enqueue_for_event(event)
    rescue
      error ->
        Logger.error("Teams.NotifierServer failed on #{inspect(event.type)}: #{inspect(error)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
