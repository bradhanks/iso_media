defmodule PerfectPaper.Billing.RiskSignals do
  @moduledoc """
  IP risk-signal lookup behaviour (anti-corruption layer) for arbitrage scrutiny.

  The adapter receives the raw IP and returns **atom-keyed flags only** — vendor
  specifics, the IP itself, and error shapes never leak past it. The context
  persists the flags + country, never the IP (data minimization, GDPR).

  Selection (single rule): `opts[:risk_signals]` (a test injection) overrides
  `config :perfect_paper, :pricing_risk_provider` (production), defaulting to the
  stub — mirroring how `Chatbot` selects its LLM provider.

  The adapter MUST bound its latency (e.g. `Req receive_timeout: 300ms`) so a hung
  lookup can't stall checkout; the context treats `{:error, _}`/timeout as
  `risk_unknown` and proceeds (flag-don't-block). A circuit breaker is Phase 2.
  """

  @type signals :: %{
          vpn?: boolean(),
          datacenter?: boolean(),
          asn: integer() | nil,
          source: atom()
        }

  @callback check(ip :: String.t(), opts :: keyword()) ::
              {:ok, signals()} | {:error, term()}

  @doc "Returns the configured (or injected) adapter module."
  @spec adapter(keyword()) :: module()
  def adapter(opts \\ []) do
    opts[:risk_signals] ||
      Application.get_env(:perfect_paper, :pricing_risk_provider, __MODULE__.Stub)
  end

  @doc """
  Looks up risk signals via the selected adapter. Returns `{:ok, signals}` or, on
  any adapter error/timeout, `:risk_unknown` — the caller proceeds either way
  (flag-don't-block). A `nil`/blank IP short-circuits to `:risk_unknown`.
  """
  @spec check(String.t() | nil, keyword()) :: {:ok, signals()} | :risk_unknown
  def check(ip, opts \\ [])
  def check(ip, _opts) when ip in [nil, ""], do: :risk_unknown

  def check(ip, opts) when is_binary(ip) do
    case adapter(opts).check(ip, opts) do
      {:ok, %{} = signals} -> {:ok, signals}
      _ -> :risk_unknown
    end
  rescue
    _ -> :risk_unknown
  catch
    :exit, _ -> :risk_unknown
  end
end
