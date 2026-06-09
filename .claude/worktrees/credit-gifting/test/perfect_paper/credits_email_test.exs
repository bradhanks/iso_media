defmodule PerfectPaper.CreditsEmailTest do
  use PerfectPaper.DataCase, async: true

  import Swoosh.TestAssertions
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Credits

  describe "grant_free_credit/3" do
    test "grants the credit and sends the celebratory activation email" do
      # unconfirmed_user_fixture sends no email, so the mailbox holds only the
      # free-credit email (Swoosh's assert_email_sent reads FIFO).
      user = unconfirmed_user_fixture()

      assert {:ok, event} = Credits.grant_free_credit(user, 1, "signup_bonus")
      assert event.amount == 1
      assert Credits.balance(user.id) == 1

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.subject == "You've got a free credit"
        assert email.html_body =~ "free credit"
        assert email.text_body =~ "free credit"
      end)
    end

    test "reflects the updated balance in the email" do
      user = unconfirmed_user_fixture()
      Credits.grant(user.id, 4, "prior")

      assert {:ok, _event} = Credits.grant_free_credit(user, 1, "weekly_free_credit")

      assert_email_sent(fn email -> assert email.html_body =~ "5 credits" end)
    end
  end

  describe "notify_low_balance/1" do
    test "emails the user their remaining balance" do
      user = unconfirmed_user_fixture()
      Credits.grant(user.id, 3, "prior")

      assert {:ok, _email} = Credits.notify_low_balance(user)

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.subject =~ "running low"
        assert email.html_body =~ "3 credits"
      end)
    end
  end
end
