defmodule PerfectPaper.Credits.NotifierServer do
  @moduledoc """
  Subscribes to the credit event topic and emails a writer whenever they receive
  a free credit (`:credit_granted`). Entirely decoupled from granting — disabling
  or changing notifications means touching only this subscriber, never the ledger.

  Errors are logged, never raised; a mail problem can't break granting.
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
  def handle_info({:credit_granted, payload}, state) do
    try do
      Credits.notify_granted(payload)
    rescue
      error -> Logger.error("NotifierServer failed: #{inspect(error)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
