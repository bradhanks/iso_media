defmodule PerfectPaperWeb.StripeWebhookControllerTest do
  # async: false — sets the global billing_provider + :stripe config.
  use PerfectPaperWeb.ConnCase, async: false

  import PerfectPaper.AccountsFixtures
  import Ecto.Query

  alias PerfectPaper.{Billing, Credits, Repo}
  alias PerfectPaper.Billing.WebhookEvent

  @secret "whsec_test_secret"

  setup do
    prev_provider = Application.get_env(:perfect_paper, :billing_provider)
    prev_stripe = Application.get_env(:perfect_paper, :stripe)
    Application.put_env(:perfect_paper, :billing_provider, PerfectPaper.Billing.StripeAdapter)
    Application.put_env(:perfect_paper, :stripe, webhook_secret: @secret)

    on_exit(fn ->
      Application.put_env(:perfect_paper, :billing_provider, prev_provider)
      Application.put_env(:perfect_paper, :stripe, prev_stripe)
    end)

    :ok
  end

  defp sub_created(user, opts) do
    cadence = opts[:cadence] || "monthly"
    interval = if cadence == "annual", do: "year", else: "month"

    Jason.encode!(%{
      "id" => opts[:event_id] || "evt_test_1",
      "type" => "customer.subscription.created",
      "data" => %{
        "object" => %{
          "id" => opts[:sub_id] || "sub_test_1",
          "customer" => "cus_test_1",
          "status" => opts[:status] || "active",
          "current_period_end" => 1_800_000_000,
          "metadata" => %{
            "user_id" => user.id,
            "plan" => opts[:plan] || "professional",
            "cadence" => cadence
          },
          "items" => %{"data" => [%{"price" => %{"recurring" => %{"interval" => interval}}}]}
        }
      }
    })
  end

  defp signature(payload) do
    ts = System.system_time(:second)
    sig = :crypto.mac(:hmac, :sha256, @secret, "#{ts}.#{payload}") |> Base.encode16(case: :lower)
    "t=#{ts},v1=#{sig}"
  end

  defp post_signed(payload) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", signature(payload))
    |> post(~p"/webhooks/stripe", payload)
  end

  test "a signed subscription.created webhook upserts the subscription" do
    user = user_fixture()
    conn = post_signed(sub_created(user, plan: "professional"))

    assert conn.status == 200
    sub = Billing.get_subscription_for_user(user.id)
    assert sub.plan == :professional
    assert sub.status == :active
    assert sub.provider_subscription_id == "sub_test_1"
    assert sub.provider_customer_id == "cus_test_1"
  end

  test "an annual subscription grants the 12-month lump during reconciliation" do
    user = user_fixture()
    conn = post_signed(sub_created(user, plan: "starter", cadence: "annual"))

    assert conn.status == 200
    # Starter annual lump: 1 review/mo × 12, granted inline.
    assert Credits.balance(user.id) == 12
  end

  test "a forged signature is rejected with 400 and changes nothing" do
    user = user_fixture()
    payload = sub_created(user, [])

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", "t=#{System.system_time(:second)},v1=deadbeef")
      |> post(~p"/webhooks/stripe", payload)

    assert conn.status == 400
    assert Billing.get_subscription_for_user(user.id) == nil
  end

  test "a duplicate event id is processed exactly once (Stripe retry safe)" do
    user = user_fixture()
    payload = sub_created(user, event_id: "evt_dup", plan: "professional")

    assert post_signed(payload).status == 200
    assert post_signed(payload).status == 200

    assert Repo.aggregate(from(e in WebhookEvent, where: e.stripe_event_id == "evt_dup"), :count) ==
             1
  end

  test "a payment-mode checkout.session.completed grants the pack's review credits" do
    user = user_fixture()

    payload =
      Jason.encode!(%{
        "id" => "evt_pack_1",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_p",
            "mode" => "payment",
            "metadata" => %{"user_id" => user.id, "pack" => "pack_6", "credits" => "6"}
          }
        }
      })

    assert post_signed(payload).status == 200
    assert Credits.balance(user.id) == 6

    # Retry is exactly-once (dedup) — no double grant.
    assert post_signed(payload).status == 200
    assert Credits.balance(user.id) == 6
  end

  test "an unhandled event type is accepted (200) and ignored" do
    payload =
      Jason.encode!(%{"id" => "evt_u", "type" => "charge.refunded", "data" => %{"object" => %{}}})

    assert post_signed(payload).status == 200
  end
end
