defmodule PerfectPaper.Credits.GrantServer do
  @moduledoc """
  Subscribes to the credit event topic and runs the matching campaigns when a
  domain event arrives (`:signup`, `:referral_accepted`, `:referral_purchase`,
  …). The emitting context just announces the event via `Credits.dispatch/2`; it
  never calls the granting logic directly — so the grant program is reignable by
  editing campaigns alone.

  Errors are logged, never raised, so one bad event can't take the server down.
  """
  use GenServer

  require Logger

  alias PerfectPaper.Credits

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Credits.subscribe()
    {:ok, %{}}
  end

  @impl true
  # Result announcements are for the notifier, not the grant runner.
  def handle_info({:credit_granted, _payload}, state), do: {:noreply, state}

  def handle_info({trigger, payload}, state) when is_atom(trigger) and is_map(payload) do
    try do
      Credits.apply_event(trigger, payload)
    rescue
      error -> Logger.error("GrantServer failed on #{inspect(trigger)}: #{inspect(error)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
