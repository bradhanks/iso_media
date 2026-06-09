defmodule PerfectPaper.BillingEmailTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias PerfectPaper.Billing

  @user %{id: "u-1", email: "scholar@example.com"}

  test "send_subscription_confirmation/2 confirms the active plan" do
    assert {:ok, _email} = Billing.send_subscription_confirmation(@user, :pro)

    assert_email_sent(fn email ->
      assert email.to == [{"", @user.email}]
      assert email.subject =~ "active"
      assert email.html_body =~ "Pro plan"
    end)
  end

  test "send_payment_receipt/3 shows the formatted amount and plan" do
    assert {:ok, _email} = Billing.send_payment_receipt(@user, 1299, :professional)

    assert_email_sent(fn email ->
      assert email.subject =~ "receipt"
      assert email.html_body =~ "$12.99"
      assert email.html_body =~ "Professional plan"
    end)
  end

  test "send_payment_failed/2 sends the dunning email" do
    assert {:ok, _email} = Billing.send_payment_failed(@user, :advanced)

    assert_email_sent(fn email ->
      assert email.subject =~ "update your payment method"
      assert email.html_body =~ "Advanced plan"
    end)
  end

  test "send_subscription_canceled/2 confirms the cancellation" do
    assert {:ok, _email} = Billing.send_subscription_canceled(@user, :professional)

    assert_email_sent(fn email ->
      assert email.subject =~ "canceled"
      assert email.html_body =~ "Professional plan"
    end)
  end
end
