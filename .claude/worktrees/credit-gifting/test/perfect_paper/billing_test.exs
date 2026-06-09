defmodule PerfectPaper.BillingTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Billing
  alias PerfectPaper.Billing.{Prices, Subscription}

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.BillingFixtures

  describe "list_products/0" do
    test "returns a non-empty list of products" do
      products = Billing.list_products()
      assert is_list(products)
      assert length(products) > 0
    end

    test "each product carries the fields a pricing card needs" do
      for product <- Billing.list_products() do
        assert Map.has_key?(product, :key)
        assert Map.has_key?(product, :name)
        assert Map.has_key?(product, :price_label)
        assert Map.has_key?(product, :features)
        assert is_list(product.features)
      end
    end

    test "includes the starter, professional, and advanced subscription plans" do
      keys = Billing.list_products() |> Enum.map(& &1.key)
      assert :starter in keys
      assert :professional in keys
      assert :advanced in keys
    end
  end

  describe "upgrade_plan/2" do
    test "creates a subscription with stub provider ids and active status" do
      user = user_fixture()
      assert {:ok, sub} = Billing.upgrade_plan(user, :professional)

      assert sub.user_id == user.id
      assert sub.plan == :professional
      assert sub.status == :active
      assert String.starts_with?(sub.provider_customer_id, "cus_stub_")
      assert String.starts_with?(sub.provider_subscription_id, "sub_stub_")
    end

    test "upgrades an existing subscription to a higher plan" do
      user = user_fixture()
      {:ok, _starter} = Billing.upgrade_plan(user, :starter)
      assert {:ok, updated} = Billing.upgrade_plan(user, :advanced)

      assert updated.user_id == user.id
      assert updated.plan == :advanced
      assert updated.status == :active
    end

    test "subscribing emits a subscription.updated event carrying the plan" do
      user = user_fixture()
      :ok = PerfectPaper.Events.subscribe(:"subscription.updated")

      assert {:ok, sub} = Billing.upgrade_plan(user, :professional)

      # The monthly-allowance grant is now decoupled: Billing announces the change
      # and Credits reacts to it (see Credits.grant_monthly_allowance_for_event/1),
      # rather than Billing calling into Credits directly.
      assert_received {:event,
                       %PerfectPaper.Events.Event{
                         type: :"subscription.updated",
                         actor_id: actor_id,
                         data: %{plan: :professional, billing_period: :monthly}
                       }}

      assert actor_id == user.id
      assert sub.plan == :professional
    end
  end

  describe "get_subscription_for_user/1" do
    test "returns the subscription after upgrade_plan" do
      user = user_fixture()
      {:ok, created} = Billing.upgrade_plan(user, :professional)
      fetched = Billing.get_subscription_for_user(user.id)

      assert fetched != nil
      assert fetched.id == created.id
      assert fetched.plan == :professional
    end

    test "returns nil when the user has no subscription" do
      user = user_fixture()
      assert Billing.get_subscription_for_user(user.id) == nil
    end
  end

  describe "cancel_plan/1" do
    test "sets status to :canceled" do
      user = user_fixture()
      sub = subscription_fixture(user, :professional)

      assert {:ok, canceled} = Billing.cancel_plan(sub)
      assert canceled.status == :canceled
    end

    test "persists the canceled status" do
      user = user_fixture()
      sub = subscription_fixture(user, :advanced)
      {:ok, _} = Billing.cancel_plan(sub)

      reloaded = Billing.get_subscription_for_user(user.id)
      assert reloaded.status == :canceled
    end
  end

  describe "downgrade_plan/2" do
    test "updates the plan on an existing subscription" do
      user = user_fixture()
      {:ok, _} = Billing.upgrade_plan(user, :advanced)
      assert {:ok, downgraded} = Billing.downgrade_plan(user, :starter)

      assert downgraded.plan == :starter
    end

    test "returns error when user has no subscription" do
      user = user_fixture()
      assert {:error, :no_subscription} = Billing.downgrade_plan(user, :starter)
    end
  end

  describe "Subscription display helpers" do
    test "predicates reflect status and plan" do
      user = user_fixture()
      {:ok, sub} = Billing.upgrade_plan(user, :professional)

      assert Subscription.active?(sub)
      refute Subscription.canceled?(sub)
      # A user with a paid subscription is not on free previews; nil is.
      refute Subscription.free?(sub)
      assert Subscription.free?(nil)
      assert Subscription.status_label(sub) == "Active"
      assert Subscription.plan_label(sub) == "Professional"
    end

    test "canceled? is true after cancel" do
      user = user_fixture()
      sub = subscription_fixture(user, :advanced)
      {:ok, canceled} = Billing.cancel_plan(sub)
      assert Subscription.canceled?(canceled)
      assert Subscription.status_label(canceled) == "Canceled"
    end
  end

  describe "Prices catalogue" do
    test "subscription plans carry display-ready price labels" do
      products = Prices.list()
      starter = Enum.find(products, &(&1.key == :starter))
      advanced = Enum.find(products, &(&1.key == :advanced))

      assert starter.price_label == "$40"
      assert advanced.price_label == "$300"
    end
  end
end
