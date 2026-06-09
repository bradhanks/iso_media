defmodule PerfectPaper.Billing.CircuitBreaker do
  @moduledoc """
  A minimal circuit breaker for the Stripe HTTP boundary.

  After `@threshold` consecutive *errorable* failures the breaker **opens** and
  short-circuits calls with `{:error, :circuit_open}` for `@cooldown_ms` — so one
  Stripe outage doesn't make every checkout wait out the full request timeout.
  After the cooldown it goes **half-open** and lets one trial through: success
  closes it, failure re-opens it.

  "Errorable" excludes client errors (a declined card / bad request) — Stripe is
  healthy, so those must not trip the breaker. The caller supplies the predicate.

  State transitions are serialized through this GenServer; the actual Stripe call
  runs in the *caller* (only the cheap allow?/report messages touch the server),
  so concurrent calls aren't serialized.
  """
  use GenServer

  require Logger

  @threshold 5
  @cooldown_ms 30_000

  @type result :: term()

  defp threshold, do: Application.get_env(:perfect_paper, :stripe_breaker_threshold, @threshold)

  defp cooldown_ms,
    do: Application.get_env(:perfect_paper, :stripe_breaker_cooldown_ms, @cooldown_ms)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs `fun` through the breaker. When open, returns `{:error, :circuit_open}`
  without calling. `opts[:errorable?]` decides which results count as failures
  (default: any `{:error, _}`).
  """
  @spec call((-> result()), keyword()) :: result() | {:error, :circuit_open}
  def call(fun, opts \\ []) when is_function(fun, 0) do
    errorable? = Keyword.get(opts, :errorable?, &default_errorable?/1)

    case GenServer.call(__MODULE__, :allow?) do
      :deny ->
        {:error, :circuit_open}

      :allow ->
        result = fun.()
        GenServer.cast(__MODULE__, {:report, errorable?.(result)})
        result
    end
  end

  @doc "Resets the breaker to closed (test helper / manual recovery)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Current breaker status (for tests / observability)."
  @spec status() :: :closed | :open | :half_open
  def status, do: GenServer.call(__MODULE__, :status)

  defp default_errorable?({:error, _}), do: true
  defp default_errorable?(_), do: false

  # ── Server ──────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{state: :closed, failures: 0, opened_at: nil}}

  @impl true
  def handle_call(:allow?, _from, %{state: :open, opened_at: opened_at} = s) do
    if now() - opened_at >= cooldown_ms() do
      # Cooldown elapsed → let one trial through.
      {:reply, :allow, %{s | state: :half_open}}
    else
      {:reply, :deny, s}
    end
  end

  def handle_call(:allow?, _from, s), do: {:reply, :allow, s}

  def handle_call(:reset, _from, _s),
    do: {:reply, :ok, %{state: :closed, failures: 0, opened_at: nil}}

  def handle_call(:status, _from, s), do: {:reply, s.state, s}

  @impl true
  # A failure while half-open (trial failed) → re-open immediately.
  def handle_cast({:report, true}, %{state: :half_open} = s) do
    {:noreply, open(s)}
  end

  def handle_cast({:report, true}, s) do
    failures = s.failures + 1

    if failures >= threshold(),
      do: {:noreply, open(s)},
      else: {:noreply, %{s | failures: failures}}
  end

  # A success closes (and resets) the breaker.
  def handle_cast({:report, false}, _s),
    do: {:noreply, %{state: :closed, failures: 0, opened_at: nil}}

  defp open(s) do
    if s.state != :open,
      do: Logger.warning("Stripe circuit breaker opened after repeated failures")

    %{s | state: :open, opened_at: now()}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
