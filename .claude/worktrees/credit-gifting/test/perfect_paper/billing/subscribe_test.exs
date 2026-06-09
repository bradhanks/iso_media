defmodule PerfectPaper.Billing.SubscribeTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.{Billing, Credits}

  import PerfectPaper.AccountsFixtures

  describe "subscribe/6 — monthly" do
    test "persists the subscription with cadence + applied pricing and audits it" do
      user = user_fixture()

      assert {:ok, sub} = Billing.subscribe(user, :starter, :monthly, "US", "US", [])

      assert sub.plan == :starter
      assert sub.billing_period == :monthly
      assert sub.applied_band == "a"
      assert sub.applied_cents == 4000

      # The purchase recorded a pricing-decision audit row.
      assert [audit] = Billing.list_pricing_decisions(user_id: user.id)
      assert audit.product == "starter"
      assert audit.cadence == "monthly"
      assert audit.applied_cents == 4000
    end

    test "announces subscription.updated for the monthly drip" do
      user = user_fixture()
      :ok = PerfectPaper.Events.subscribe(:"subscription.updated")

      assert {:ok, _sub} = Billing.subscribe(user, :professional, :monthly, "US", "US", [])

      assert_received {:event,
                       %PerfectPaper.Events.Event{
                         type: :"subscription.updated",
                         data: %{plan: :professional, billing_period: :monthly}
                       }}
    end
  end

  describe "subscribe/6 — annual" do
    test "grants the 12-month lump in-transaction and suppresses the monthly drip" do
      user = user_fixture()

      assert {:ok, sub} = Billing.subscribe(user, :starter, :annual, "US", "US", [])

      assert sub.billing_period == :annual
      # Starter annual = 10 months charged.
      assert sub.applied_cents == 40_000
      # Lump granted synchronously inside the purchase transaction: 1/mo × 12.
      assert Credits.balance(user.id) == 12
    end

    test "re-subscribing within the term does not double-grant the lump" do
      user = user_fixture()
      assert {:ok, _} = Billing.subscribe(user, :professional, :annual, "US", "US", [])
      assert {:ok, _} = Billing.subscribe(user, :professional, :annual, "US", "US", [])
      # 3 reviews/mo × 12, once.
      assert Credits.balance(user.id) == 36
    end
  end

  describe "subscribe/6 — binding band" do
    test "the less-generous of IP/payment binds (spoofed IP yields no discount)" do
      user = user_fixture()
      assert {:ok, sub} = Billing.subscribe(user, :starter, :monthly, "IN", "US", [])
      assert sub.applied_band == "a"
      assert sub.applied_cents == 4000
    end

    test "a genuine low-band payment country binds the discount" do
      user = user_fixture()
      assert {:ok, sub} = Billing.subscribe(user, :starter, :monthly, "IN", "IN", [])
      assert sub.applied_band == "c"
      assert sub.applied_cents == 2000
    end
  end

  describe "subscribe/6 — guards" do
    test "rejects a non-user (org/group) context" do
      assert {:error, :org_purchase_unsupported} =
               Billing.subscribe(%{id: "org-1"}, :starter, :monthly, "US", "US", [])
    end

    test "rejects an unknown plan (e.g. a pack key)" do
      user = user_fixture()
      assert {:error, :unknown_plan} = Billing.subscribe(user, :pack_3, :monthly, "US", "US", [])
    end
  end
end
