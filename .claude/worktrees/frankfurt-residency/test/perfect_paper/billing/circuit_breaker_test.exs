defmodule PerfectPaper.Billing.CircuitBreakerTest do
  # async: false — a shared singleton GenServer + global threshold/cooldown config.
  use ExUnit.Case, async: false

  alias PerfectPaper.Billing.CircuitBreaker

  setup do
    prev_t = Application.get_env(:perfect_paper, :stripe_breaker_threshold)
    prev_c = Application.get_env(:perfect_paper, :stripe_breaker_cooldown_ms)
    Application.put_env(:perfect_paper, :stripe_breaker_threshold, 3)
    Application.put_env(:perfect_paper, :stripe_breaker_cooldown_ms, 50)
    CircuitBreaker.reset()

    on_exit(fn ->
      Application.put_env(:perfect_paper, :stripe_breaker_threshold, prev_t)
      Application.put_env(:perfect_paper, :stripe_breaker_cooldown_ms, prev_c)
      CircuitBreaker.reset()
    end)

    :ok
  end

  defp fail, do: CircuitBreaker.call(fn -> {:error, :boom} end)
  defp ok, do: CircuitBreaker.call(fn -> {:ok, :fine} end)

  test "passes results through and stays closed under the threshold" do
    assert {:ok, :fine} = ok()
    assert {:error, :boom} = fail()
    assert {:error, :boom} = fail()
    assert CircuitBreaker.status() == :closed
  end

  test "opens after threshold consecutive failures and short-circuits the call" do
    for _ <- 1..3, do: fail()
    assert CircuitBreaker.status() == :open

    # Open → returns immediately without invoking the function.
    assert {:error, :circuit_open} = CircuitBreaker.call(fn -> {:ok, :should_not_run} end)
  end

  test "a success resets the failure count" do
    fail()
    fail()
    ok()
    fail()
    fail()
    assert CircuitBreaker.status() == :closed
  end

  test "non-errorable results (client errors) never open the breaker" do
    for _ <- 1..5,
        do: CircuitBreaker.call(fn -> {:error, :declined} end, errorable?: fn _ -> false end)

    assert CircuitBreaker.status() == :closed
  end

  test "half-opens after the cooldown and closes on a successful trial" do
    for _ <- 1..3, do: fail()
    assert CircuitBreaker.status() == :open

    Process.sleep(70)
    assert {:ok, :fine} = ok()
    assert CircuitBreaker.status() == :closed
  end

  test "re-opens if the half-open trial fails" do
    for _ <- 1..3, do: fail()
    Process.sleep(70)

    assert {:error, :boom} = fail()
    assert CircuitBreaker.status() == :open
  end
end
