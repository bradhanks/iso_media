defmodule PerfectPaper.CreditsCrossingTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Credits
  import PerfectPaper.AccountsFixtures

  # grant/4 adds credits to the :paid bucket; default monthly threshold = 1.
  defp grant(user_id, n), do: Credits.grant(user_id, n, "test_grant", :paid)

  test "the charge that lands on the threshold reports crossed_low? == true, exactly once" do
    user = user_fixture()
    grant(user.id, 3)

    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)
    assert {:ok, _e, true} = Credits.charge_for_proofreading(user.id)
    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)
  end

  test "re-arms after a top-up above threshold" do
    user = user_fixture()
    grant(user.id, 2)
    assert {:ok, _e, true} = Credits.charge_for_proofreading(user.id)
    grant(user.id, 2)
    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)
    assert {:ok, _e, true} = Credits.charge_for_proofreading(user.id)
  end

  test "threshold 0 (disabled) never reports a crossing even at zero balance" do
    user = user_fixture()

    {:ok, user} =
      PerfectPaper.Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: 0})

    grant(user.id, 2)
    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)
    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)
  end

  test "Credits no longer emits :credits.low itself" do
    PerfectPaper.Events.subscribe(:"credits.low")
    user = user_fixture()
    grant(user.id, 2)
    assert {:ok, _e, true} = Credits.charge_for_proofreading(user.id)
    refute_receive {:event, %PerfectPaper.Events.Event{type: :"credits.low"}}, 200
  end
end
