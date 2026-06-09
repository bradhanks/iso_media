defmodule PerfectPaperWeb.RateLimit do
  @moduledoc """
  Web-layer rate limiting for auth endpoints.

  Thin anti-corruption wrapper over Hammer: callers pass a bucket key, a window
  in milliseconds, and a max count, and get back `:ok` or `:rate_limited` —
  never Hammer's internal return shape. Backed by a supervised ETS store
  (`#{__MODULE__}.Store`).
  """

  defmodule Store do
    @moduledoc false
    use Hammer, backend: :ets
  end

  @doc """
  Records a hit against `key` and reports whether it is within `limit` for the
  rolling `window_ms` window.
  """
  @spec check(String.t(), pos_integer(), pos_integer()) :: :ok | :rate_limited
  def check(key, window_ms, limit)
      when is_binary(key) and is_integer(window_ms) and window_ms > 0 and
             is_integer(limit) and limit > 0 do
    case Store.hit(key, window_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> :rate_limited
    end
  end
end
