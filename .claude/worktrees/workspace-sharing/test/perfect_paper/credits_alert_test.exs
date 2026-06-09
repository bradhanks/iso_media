defmodule PerfectPaper.CreditsAlertTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.{Accounts, Billing, Credits}

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.BillingFixtures

  # ── effective_alert_threshold/1 ─────────────────────────────────────────────

  describe "effective_alert_threshold/1" do
    test "returns the user's explicit setting when set" do
      user = user_fixture()
      {:ok, user} = Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: 10})
      assert Credits.effective_alert_threshold(user.id) == 10
    end

    test "returns 5 for an annual subscriber with no explicit setting" do
      user = user_fixture()
      sub = subscription_fixture(user, :professional)
      {:ok, _} = Billing.set_billing_period(sub, :annual)
      assert Credits.effective_alert_threshold(user.id) == 5
    end

    test "returns 1 for a monthly subscriber with no explicit setting" do
      user = user_fixture()
      _sub = subscription_fixture(user, :professional)
      assert Credits.effective_alert_threshold(user.id) == 1
    end

    test "returns 1 for a user with no subscription and no explicit setting" do
      user = user_fixture()
      assert Credits.effective_alert_threshold(user.id) == 1
    end

    test "explicit setting overrides the annual default" do
      user = user_fixture()
      sub = subscription_fixture(user, :professional)
      {:ok, _} = Billing.set_billing_period(sub, :annual)
      {:ok, user} = Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: 3})
      assert Credits.effective_alert_threshold(user.id) == 3
    end

    test "explicit threshold of 0 is respected (disables the alert)" do
      user = user_fixture()
      {:ok, user} = Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: 0})
      assert Credits.effective_alert_threshold(user.id) == 0
    end
  end

  # ── Accounts.update_credit_alert_threshold/2 ─────────────────────────────────

  describe "Accounts.update_credit_alert_threshold/2" do
    test "persists a non-negative integer threshold" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: 7})

      assert updated.credit_alert_threshold == 7
    end

    test "clears the threshold when nil is passed" do
      user = user_fixture()
      {:ok, user} = Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: 7})

      {:ok, updated} =
        Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: nil})

      assert is_nil(updated.credit_alert_threshold)
    end

    test "rejects negative values" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: -1})

      assert %{credit_alert_threshold: [_ | _]} = errors_on(changeset)
    end

    test "rejects non-integer strings" do
      user = user_fixture()

      assert {:error, _changeset} =
               Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: "lots"})
    end

    test "rejects values above the largest pack (12) so the banner can't be permanently-on" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_credit_alert_threshold(user, %{credit_alert_threshold: 13})

      assert %{credit_alert_threshold: [_ | _]} = errors_on(changeset)
    end
  end

  # ── Billing.set_billing_period/2 ─────────────────────────────────────────────

  describe "Billing.set_billing_period/2" do
    test "sets billing period to annual" do
      user = user_fixture()
      sub = subscription_fixture(user)
      assert {:ok, updated} = Billing.set_billing_period(sub, :annual)
      assert updated.billing_period == :annual
    end

    test "sets billing period back to monthly" do
      user = user_fixture()
      sub = subscription_fixture(user)
      {:ok, sub} = Billing.set_billing_period(sub, :annual)
      assert {:ok, updated} = Billing.set_billing_period(sub, :monthly)
      assert updated.billing_period == :monthly
    end

    test "rejects invalid billing periods" do
      user = user_fixture()
      sub = subscription_fixture(user)
      assert {:error, _changeset} = Billing.set_billing_period(sub, :quarterly)
    end
  end

  # NOTE: the low-balance crossing + emit moved out of Credits. The crossing flag
  # is tested in credits_crossing_test.exs; the post-commit :"credits.low" emit
  # (and its billing_period/threshold/crossing_id payload) in
  # history_low_credit_test.exs. Credits.charge_* no longer emits directly.
end
