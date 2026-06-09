defmodule PerfectPaper.ReferralsEmailTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias PerfectPaper.Referrals

  test "send_referral_invitation/3 invites a friend on the referrer's behalf" do
    referrer = %{id: "u-1", email: "deanna@example.com"}

    assert {:ok, _email} =
             Referrals.send_referral_invitation(
               referrer,
               "friend@example.com",
               "https://perfectpaper.org/r/xyz"
             )

    assert_email_sent(fn email ->
      assert email.to == [{"", "friend@example.com"}]
      assert email.subject =~ "deanna@example.com"
      assert email.html_body =~ "free credit"
      assert email.html_body =~ "https://perfectpaper.org/r/xyz"
    end)
  end

  test "notify_reward_earned/3 tells the referrer about their reward" do
    referrer = %{id: "u-1", email: "deanna@example.com"}

    assert {:ok, _email} =
             Referrals.notify_reward_earned(referrer, 10, "https://perfectpaper.org/earn")

    assert_email_sent(fn email ->
      assert email.to == [{"", "deanna@example.com"}]
      assert email.subject =~ "reward"
      assert email.html_body =~ "10 credits"
    end)
  end
end
