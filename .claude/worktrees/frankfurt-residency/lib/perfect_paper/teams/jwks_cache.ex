defmodule PerfectPaper.Teams.JwksCache do
  @moduledoc """
  Caches the Bot Framework JWKS signing keys in memory (~24h TTL) so the inbound
  verifier never fetches Microsoft's keys per-request (avoids bottleneck + MS
  downtime). `TODO(teams)`: the live fetch from the Bot Framework OpenID metadata
  (`https://login.botframework.com/v1/.well-known/keys`) + scheduled refresh.
  """
  use GenServer

  @ttl_ms 24 * 60 * 60 * 1000

  @doc "Starts the JwksCache GenServer (registered under its module name)."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the cached JWKS keys (empty list until the real adapter populates them)."
  @spec keys() :: list()
  def keys, do: GenServer.call(__MODULE__, :keys)

  @impl true
  def init(_opts), do: {:ok, %{keys: [], fetched_at: nil}}

  @impl true
  def handle_call(:keys, _from, state), do: {:reply, state.keys, state}

  # TODO(teams): handle_info(:refresh, ...) fetches + schedules
  # Process.send_after(self(), :refresh, @ttl_ms)
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms, do: @ttl_ms
end
