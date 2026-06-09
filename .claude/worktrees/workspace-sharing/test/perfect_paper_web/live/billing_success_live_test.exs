defmodule PerfectPaperWeb.BillingSuccessLiveTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Billing
  alias PerfectPaper.Events.Event

  defp sub_event(actor_id, plan),
    do: {:event, %Event{type: :"subscription.updated", actor_id: actor_id, data: %{plan: plan}}}

  test "shows success immediately when the subscription is already active", %{conn: conn} do
    user = user_fixture()
    {:ok, _} = Billing.subscribe(user, :professional, :monthly, "US", "US", [])

    {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/billing/success")

    assert html =~ "checkout-success"
    assert html =~ "on Professional"
  end

  test "shows the activating spinner, then flips to success on the webhook event", %{conn: conn} do
    user = user_fixture()
    {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/billing/success")

    assert html =~ "checkout-pending"
    assert html =~ "Activating your plan"

    # Simulate the subscription webhook landing (reconciler emits subscription.updated).
    send(lv.pid, sub_event(user.id, :advanced))
    html = render(lv)

    assert html =~ "checkout-success"
    assert html =~ "on Advanced"
  end

  test "ignores a subscription event for a different user", %{conn: conn} do
    user = user_fixture()
    other = user_fixture()
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing/success")

    send(lv.pid, sub_event(other.id, :advanced))
    assert render(lv) =~ "checkout-pending"
  end

  test "times out to a 'payment received' fallback when no webhook arrives", %{conn: conn} do
    user = user_fixture()
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/billing/success")

    send(lv.pid, :activation_timeout)
    html = render(lv)

    assert html =~ "checkout-timed_out"
    assert html =~ "Payment received"
  end
end
