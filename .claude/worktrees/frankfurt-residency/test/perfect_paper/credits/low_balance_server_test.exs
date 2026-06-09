defmodule PerfectPaper.Credits.LowBalanceServerTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Events
  alias PerfectPaper.Credits.{LowBalanceServer, LowBalanceUpsellWorker}

  # Exercise handle_info/2 directly: the globally-supervised server runs in its
  # own process outside the test's SQL sandbox, so its Oban.insert wouldn't be
  # visible to all_enqueued. Calling handle_info in the test process keeps the
  # insert on the sandboxed connection while testing the exact dispatch logic.
  test "a credits.low event enqueues the upsell job with the event payload" do
    user = user_fixture()

    event = %Events.Event{
      type: :"credits.low",
      actor_id: user.id,
      data: %{balance: 1, threshold: 1, billing_period: :monthly, crossing_id: "cx-9"}
    }

    assert {:noreply, %{}} = LowBalanceServer.handle_info({:event, event}, %{})

    assert [job] = all_enqueued(worker: LowBalanceUpsellWorker)
    assert job.args["user_id"] == user.id
    assert job.args["crossing_id"] == "cx-9"
    assert job.args["balance"] == 1
    assert job.args["threshold"] == 1
  end

  test "an unrelated message is ignored" do
    assert {:noreply, %{}} = LowBalanceServer.handle_info(:something_else, %{})
  end
end
