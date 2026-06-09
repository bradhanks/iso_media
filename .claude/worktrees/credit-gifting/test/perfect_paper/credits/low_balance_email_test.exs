defmodule PerfectPaper.Credits.LowBalanceEmailTest do
  use PerfectPaper.DataCase, async: true
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.BillingFixtures
  import Swoosh.TestAssertions
  alias PerfectPaper.Credits

  test "non-annual user gets the upsell with the 12-pack CTA at the Band-A price" do
    user = user_fixture()
    assert {:ok, _email} = Credits.deliver_low_balance_upsell(user, 1, 1)

    assert_email_sent(fn email ->
      assert email.to == [{"", user.email}]
      # Band-A 12-pack price ($498 after psych-rounding the 17%-off $599.99)
      assert email.html_body =~ "$498"
      assert email.subject != ""
    end)
  end

  test "annual subscriber gets the 'finish your year' copy variant" do
    user = user_fixture()
    {:ok, _sub} = annual_subscription_for(user)
    assert {:ok, email} = Credits.deliver_low_balance_upsell(user, 4, 5)
    assert email.html_body =~ "year" or email.text_body =~ "year"
  end

  test "a user without an email address is a no-op (no crash)" do
    assert {:error, :no_email} =
             Credits.deliver_low_balance_upsell(%{id: Ecto.UUID.generate(), email: nil}, 1, 1)
  end
end
