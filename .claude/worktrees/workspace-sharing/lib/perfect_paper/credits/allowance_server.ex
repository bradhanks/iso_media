defmodule PerfectPaper.Credits.AllowanceServer do
  @moduledoc """
  Subscribes to the `subscription.updated` domain event and drops the plan's
  monthly review allowance into the ledger when a plan change arrives. Billing
  just announces the change via `Events.emit/2`; it never calls the granting
  logic directly — so the allowance stays decoupled from billing.

  The grant itself is idempotent per calendar month (see
  `Credits.grant_monthly_allowance_for_event/1`), so a re-emitted event is safe.
  Errors are logged, never raised, so one bad event can't take the server down.
  """
  use GenServer

  require Logger

  alias PerfectPaper.{Credits, Events}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Events.subscribe(:"subscription.updated")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:event, %Events.Event{} = event}, state) do
    try do
      Credits.grant_monthly_allowance_for_event(event)
    rescue
      error -> Logger.error("AllowanceServer failed on #{inspect(event.type)}: #{inspect(error)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
