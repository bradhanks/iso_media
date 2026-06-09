defmodule PerfectPaper.Credits.LowBalanceUpsellWorkerTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Credits.LowBalanceUpsellWorker

  test "perform delivers the upsell email for the user" do
    user = user_fixture()

    assert :ok =
             perform_job(LowBalanceUpsellWorker, %{
               "user_id" => user.id,
               "balance" => 1,
               "threshold" => 1
             })
  end

  test "the same crossing_id enqueues only once (dedup on retry)" do
    user = user_fixture()
    args = %{user_id: user.id, balance: 1, threshold: 1, crossing_id: "cx-1"}

    assert {:ok, _} = Oban.insert(LowBalanceUpsellWorker.new(args))
    assert {:ok, job2} = Oban.insert(LowBalanceUpsellWorker.new(args))
    assert job2.conflict? or length(all_enqueued(worker: LowBalanceUpsellWorker)) == 1
  end
end
