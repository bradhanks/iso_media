defmodule PerfectPaper.HistoryLowCreditTest do
  use PerfectPaper.DataCase, async: false
  alias PerfectPaper.{Credits, Events, History}
  import PerfectPaper.AccountsFixtures

  setup do
    Events.subscribe(:"credits.low")
    :ok
  end

  defp grant(user_id, n), do: Credits.grant(user_id, n, "test_grant", :paid)

  test "a committed review that crosses the threshold emits credits.low once, post-commit" do
    user = user_fixture()
    # threshold defaults to 1; granting 2 means the review charge (2 -> 1) crosses.
    grant(user.id, 2)
    {:ok, session} = History.begin_session(%{user_id: user.id, title: "Paper"})

    assert {:ok, _reviewed} = History.process_session(session, "manuscript text")

    assert_receive {:event, %Events.Event{type: :"credits.low", actor_id: actor, data: data}}
    assert actor == user.id
    assert data.balance == 1
    assert data.threshold == 1
    assert is_binary(data.crossing_id)
    refute_receive {:event, %Events.Event{type: :"credits.low"}}, 200
  end

  test "a review that does not cross the threshold emits no credits.low" do
    user = user_fixture()
    grant(user.id, 5)
    {:ok, session} = History.begin_session(%{user_id: user.id, title: "Paper"})

    assert {:ok, _reviewed} = History.process_session(session, "manuscript text")

    refute_receive {:event, %Events.Event{type: :"credits.low"}}, 200
  end
end
