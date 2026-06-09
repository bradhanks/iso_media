defmodule PerfectPaper.Billing.StripeAdapterTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Billing.StripeAdapter

  describe "translate_event/1 — subscription lifecycle" do
    defp sub_object(overrides \\ %{}) do
      Map.merge(
        %{
          "id" => "sub_123",
          "customer" => "cus_123",
          "status" => "active",
          "current_period_end" => 1_780_000_000,
          "metadata" => %{"user_id" => "u-1", "plan" => "professional", "cadence" => "monthly"},
          "items" => %{"data" => [%{"price" => %{"recurring" => %{"interval" => "month"}}}]}
        },
        overrides
      )
    end

    test "customer.subscription.created → :subscription_upserted with mapped attrs" do
      raw = %{
        "id" => "evt_1",
        "type" => "customer.subscription.created",
        "data" => %{"object" => sub_object()}
      }

      assert {:ok, event} = StripeAdapter.translate_event(raw)
      assert event.event_id == "evt_1"
      assert event.action == :subscription_upserted

      d = event.data
      assert d.provider_subscription_id == "sub_123"
      assert d.provider_customer_id == "cus_123"
      assert d.user_id == "u-1"
      assert d.plan == :professional
      assert d.billing_period == :monthly
      assert d.status == :active
      assert %DateTime{} = d.current_period_end
    end

    test "annual interval maps billing_period to :annual" do
      object =
        sub_object(%{
          "metadata" => %{"user_id" => "u-1", "plan" => "starter", "cadence" => "annual"}
        })

      raw = %{
        "id" => "evt_2",
        "type" => "customer.subscription.updated",
        "data" => %{"object" => object}
      }

      assert {:ok, %{data: %{billing_period: :annual}}} = StripeAdapter.translate_event(raw)
    end

    test "past_due / canceled statuses map through" do
      for {stripe, ours} <- [
            {"past_due", :past_due},
            {"canceled", :canceled},
            {"unpaid", :past_due}
          ] do
        raw = %{
          "id" => "evt_s",
          "type" => "customer.subscription.updated",
          "data" => %{"object" => sub_object(%{"status" => stripe})}
        }

        assert {:ok, %{data: %{status: ^ours}}} = StripeAdapter.translate_event(raw)
      end
    end

    test "customer.subscription.deleted → :subscription_canceled" do
      raw = %{
        "id" => "evt_3",
        "type" => "customer.subscription.deleted",
        "data" => %{"object" => sub_object()}
      }

      assert {:ok, event} = StripeAdapter.translate_event(raw)
      assert event.action == :subscription_canceled
      assert event.data.provider_subscription_id == "sub_123"
      assert event.data.user_id == "u-1"
    end

    test "checkout.session.completed → :checkout_completed with mode + metadata" do
      raw = %{
        "id" => "evt_4",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_9",
            "subscription" => "sub_9",
            "mode" => "payment",
            "metadata" => %{"user_id" => "u-9", "pack" => "pack_3", "credits" => "3"}
          }
        }
      }

      assert {:ok, event} = StripeAdapter.translate_event(raw)
      assert event.action == :checkout_completed
      assert event.data.provider_customer_id == "cus_9"
      assert event.data.user_id == "u-9"
      assert event.data.mode == "payment"
      assert event.data.metadata["credits"] == "3"
    end

    test "an unhandled event type is reported as :unhandled_event" do
      raw = %{"id" => "evt_x", "type" => "charge.refunded", "data" => %{"object" => %{}}}
      assert {:error, :unhandled_event} = StripeAdapter.translate_event(raw)
    end

    test "a malformed payload is :unhandled_event, not a crash" do
      assert {:error, :unhandled_event} = StripeAdapter.translate_event(%{"nope" => true})
    end
  end
end
