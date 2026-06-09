defmodule PerfectPaper.CreditsConcurrencyTest do
  @moduledoc """
  Dark-dimension interleaving oracle for the credit system.

  pg_advisory_xact_lock is held at the outer BEGIN transaction level, NOT at
  SAVEPOINT level. The Ecto sandbox wraps every checkout in a BEGIN that lives
  for the process lifetime, so concurrent tasks in sandbox mode can't release
  the lock between operations (each task holds it for its entire existence).
  We switch to :auto mode (real Postgres transactions with real COMMITs) so the
  OS scheduler can actually interleave and the advisory lock races for real.

  These are INDEPENDENT ORACLES: we do NOT read code to conclude "the lock
  should prevent double-spend." We let Postgres and the OS scheduler arbitrate
  among concurrent callers and count what actually happened.

  Mutation proof (recorded 2026-06-07):
    - Removing lock_user from charge/3: 19/20 charges succeed against 3 credits
    - Removing lock_user from locked_insert: 20/20 grants fire for one month period
    - Both bugs invisible to the 33 existing sequential credit tests
  """
  use ExUnit.Case, async: false

  alias PerfectPaper.{Repo, Credits, Accounts}
  alias PerfectPaper.Accounts.User
  import Ecto.Query

  @n_tasks 20
  @n_credits 3

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    email = "concurrency_oracle_#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email})

    on_exit(fn ->
      # on_delete: :delete_all on credit_events.user_id cascades automatically
      Repo.delete_all(from u in User, where: u.email == ^email)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    {:ok, user_id: user.id}
  end

  @tag timeout: 30_000
  test "advisory lock: #{@n_credits} credits, #{@n_tasks} concurrent charges → exactly #{@n_credits} succeed",
       %{user_id: user_id} do
    {:ok, _} = Credits.grant(user_id, @n_credits, "concurrency_oracle_setup")

    results =
      1..@n_tasks
      |> Task.async_stream(
        fn _ -> Credits.charge_for_proofreading(user_id) end,
        max_concurrency: @n_tasks,
        timeout: 20_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    successes = Enum.count(results, &match?({:ok, _, _}, &1))
    failures = Enum.count(results, &match?({:error, :insufficient_credits}, &1))

    assert successes == @n_credits,
           "DOUBLE-SPEND: #{successes} charges succeeded but only #{@n_credits} credits existed." <>
             "\nfailures=#{failures}"

    final = Credits.balance(user_id)

    assert final >= 0,
           "NEGATIVE BALANCE: #{final}. Advisory lock did not serialize correctly."

    assert final == 0,
           "UNDERSPEND: balance=#{final}, expected 0. #{@n_credits - successes} credits stranded."
  end

  @tag timeout: 30_000
  test "locked_insert: #{@n_tasks} concurrent monthly allowance grants → exactly 1 grant",
       %{user_id: user_id} do
    period = "2026-06-oracle-test"

    results =
      1..@n_tasks
      |> Task.async_stream(
        fn _ -> Credits.grant_monthly_allowance(user_id, :professional, period: period) end,
        max_concurrency: @n_tasks,
        timeout: 20_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    grants = Enum.count(results, &match?({:ok, %{}}, &1))
    already = Enum.count(results, &match?({:ok, :already_granted}, &1))

    assert grants == 1,
           "DOUBLE-GRANT: #{grants} allowances inserted for one period. locked_insert race." <>
             "\nalready_granted=#{already}"

    assert grants + already == @n_tasks

    final = Credits.balance(user_id)
    assert final == 3, "Expected 3 credits (professional plan), got #{final}"
  end
end
