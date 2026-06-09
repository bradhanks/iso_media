defmodule PerfectPaperWeb.RateLimitTest do
  use ExUnit.Case, async: true

  alias PerfectPaperWeb.RateLimit

  # Unique key per test run so buckets never collide across runs.
  defp key, do: "test:#{System.unique_integer([:positive])}"

  test "allows calls up to the limit, then blocks" do
    k = key()
    assert RateLimit.check(k, 60_000, 3) == :ok
    assert RateLimit.check(k, 60_000, 3) == :ok
    assert RateLimit.check(k, 60_000, 3) == :ok
    assert RateLimit.check(k, 60_000, 3) == :rate_limited
  end

  test "independent keys have independent buckets" do
    a = key()
    b = key()
    assert RateLimit.check(a, 60_000, 1) == :ok
    assert RateLimit.check(a, 60_000, 1) == :rate_limited
    assert RateLimit.check(b, 60_000, 1) == :ok
  end
end
