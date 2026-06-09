defmodule PerfectPaper.CreditsThresholdTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Credits

  defp user(t), do: %PerfectPaper.Accounts.User{credit_alert_threshold: t}
  defp annual, do: %PerfectPaper.Billing.Subscription{billing_period: :annual}
  defp monthly, do: %PerfectPaper.Billing.Subscription{billing_period: :monthly}

  test "annual subscriber with no override defaults to 5" do
    assert Credits.effective_low_credit_threshold(user(nil), annual()) == 5
  end

  test "non-annual / no subscription with no override defaults to 1" do
    assert Credits.effective_low_credit_threshold(user(nil), monthly()) == 1
    assert Credits.effective_low_credit_threshold(user(nil), nil) == 1
  end

  test "explicit user value overrides the plan default" do
    assert Credits.effective_low_credit_threshold(user(8), annual()) == 8
    assert Credits.effective_low_credit_threshold(user(3), nil) == 3
  end

  test "explicit 0 is preserved (means disabled — the trigger guards on > 0)" do
    assert Credits.effective_low_credit_threshold(user(0), annual()) == 0
  end
end
