defmodule PerfectPaper.CreditsTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Credits

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.CreditsFixtures
  import Swoosh.TestAssertions

  describe "balance/1" do
    test "starts at zero for a new user" do
      user = user_fixture()
      assert Credits.balance(user.id) == 0
    end
  end

  describe "grant/3" do
    test "increases the user's balance by the granted amount" do
      user = user_fixture()
      assert {:ok, event} = Credits.grant(user.id, 50, "test_grant")
      assert event.amount == 50
      assert Credits.balance(user.id) == 50
    end

    test "accumulates across multiple grants" do
      user = user_fixture()
      Credits.grant(user.id, 30, "first")
      Credits.grant(user.id, 70, "second")
      assert Credits.balance(user.id) == 100
    end
  end

  describe "comp_account/4" do
    test "increases the balance and records attribution metadata" do
      user = user_fixture()
      admin = user_fixture()

      assert {:ok, event} =
               Credits.comp_account(user.id, 25, "sorry for the outage", admin.id)

      assert event.amount == 25
      assert event.reason == "sorry for the outage"
      assert event.metadata["kind"] == "comp"
      assert event.metadata["granted_by"] == admin.id
      assert Credits.balance(user.id) == 25
    end

    test "rejects a non-positive amount via the guard" do
      user = user_fixture()
      admin = user_fixture()

      assert_raise FunctionClauseError, fn ->
        Credits.comp_account(user.id, 0, "nope", admin.id)
      end
    end
  end

  describe "charge_for_proofreading/1" do
    test "deducts one credit (1 credit = 1 full review)" do
      user = user_fixture()
      grant_fixture(user, 100)
      assert {:ok, event, _crossed?} = Credits.charge_for_proofreading(user.id)
      assert event.amount == -1
      assert event.reason == "proofreading"
      assert Credits.balance(user.id) == 99
    end

    test "charges down to the last credit" do
      user = user_fixture()
      grant_fixture(user, 1)
      assert {:ok, _event, _crossed?} = Credits.charge_for_proofreading(user.id)
      assert Credits.balance(user.id) == 0
      assert {:error, :insufficient_credits} = Credits.charge_for_proofreading(user.id)
    end

    test "does not alter the balance when insufficient credits" do
      user = user_fixture()
      assert {:error, :insufficient_credits} = Credits.charge_for_proofreading(user.id)
      assert Credits.balance(user.id) == 0
    end

    test "returns {:error, :insufficient_credits} when balance is exactly zero" do
      user = user_fixture()
      assert {:error, :insufficient_credits} = Credits.charge_for_proofreading(user.id)
    end
  end

  describe "limits_for/1" do
    test "returns each paid plan's monthly reviews at the full processing level" do
      assert Credits.limits_for(:starter) == %{monthly_reviews: 1, level: :full}
      assert Credits.limits_for(:professional) == %{monthly_reviews: 3, level: :full}
      assert Credits.limits_for(:advanced) == %{monthly_reviews: 10, level: :full}
    end

    test "returns the throttled preview entitlement for non-subscribers" do
      assert Credits.limits_for(:preview) == %{monthly_reviews: 0, level: :preview}
    end

    test "defaults to the preview entitlement for an unknown or nil plan" do
      assert Credits.limits_for(:unknown_plan) == %{monthly_reviews: 0, level: :preview}
      assert Credits.limits_for(nil) == %{monthly_reviews: 0, level: :preview}
    end
  end

  describe "grant_monthly_allowance/3" do
    test "grants the plan's monthly review credits into the balance" do
      user = user_fixture()
      assert {:ok, event} = Credits.grant_monthly_allowance(user.id, :professional)
      assert event.amount == 3
      assert Credits.balance(user.id) == 3
    end

    test "is idempotent within a calendar month" do
      user = user_fixture()
      assert {:ok, event} = Credits.grant_monthly_allowance(user.id, :advanced, period: "2026-06")
      assert event.amount == 10

      assert {:ok, :already_granted} =
               Credits.grant_monthly_allowance(user.id, :advanced, period: "2026-06")

      assert Credits.balance(user.id) == 10
    end

    test "grants again in a new period" do
      user = user_fixture()
      {:ok, _} = Credits.grant_monthly_allowance(user.id, :starter, period: "2026-06")
      {:ok, _} = Credits.grant_monthly_allowance(user.id, :starter, period: "2026-07")
      assert Credits.balance(user.id) == 2
    end

    test "grants nothing for the preview entitlement" do
      user = user_fixture()
      assert {:ok, :no_allowance} = Credits.grant_monthly_allowance(user.id, :preview)
      assert Credits.balance(user.id) == 0
    end
  end

  describe "grant_annual_allowance/3" do
    test "grants 12 months of the plan's allowance up front, once" do
      user = user_fixture()

      assert {:ok, event} =
               Credits.grant_annual_allowance(user.id, :professional, subscription_id: "sub-1")

      # 3 reviews/mo × 12 months.
      assert event.amount == 36
      assert Credits.balance(user.id) == 36
    end

    test "is idempotent within a subscription term" do
      user = user_fixture()
      opts = [subscription_id: "sub-1", term_start: "2026-06"]

      assert {:ok, event} = Credits.grant_annual_allowance(user.id, :starter, opts)
      assert event.amount == 12
      assert {:ok, :already_granted} = Credits.grant_annual_allowance(user.id, :starter, opts)
      assert Credits.balance(user.id) == 12
    end

    test "grants again for a new term (renewal)" do
      user = user_fixture()

      {:ok, _} =
        Credits.grant_annual_allowance(user.id, :starter,
          subscription_id: "sub-1",
          term_start: "2026-06"
        )

      {:ok, _} =
        Credits.grant_annual_allowance(user.id, :starter,
          subscription_id: "sub-1",
          term_start: "2027-06"
        )

      assert Credits.balance(user.id) == 24
    end

    test "keys idempotency per subscription, not per user" do
      user = user_fixture()
      {:ok, _} = Credits.grant_annual_allowance(user.id, :starter, subscription_id: "sub-1")
      {:ok, _} = Credits.grant_annual_allowance(user.id, :starter, subscription_id: "sub-2")
      assert Credits.balance(user.id) == 24
    end

    test "grants nothing for the preview entitlement" do
      user = user_fixture()

      assert {:ok, :no_allowance} =
               Credits.grant_annual_allowance(user.id, :preview, subscription_id: "sub-1")

      assert Credits.balance(user.id) == 0
    end
  end

  describe "grant_monthly_allowance_for_event/1" do
    alias PerfectPaper.Events.Event

    test "grants the event's plan allowance to the actor" do
      user = user_fixture()

      event = %Event{
        type: :"subscription.updated",
        actor_id: user.id,
        data: %{plan: :professional, status: :active}
      }

      assert {:ok, granted} = Credits.grant_monthly_allowance_for_event(event)
      assert granted.amount == 3
      assert Credits.balance(user.id) == 3
    end

    test "drips monthly when billing_period is :monthly" do
      user = user_fixture()

      event = %Event{
        type: :"subscription.updated",
        actor_id: user.id,
        data: %{plan: :professional, billing_period: :monthly}
      }

      assert {:ok, granted} = Credits.grant_monthly_allowance_for_event(event)
      assert granted.amount == 3
    end

    test "suppresses the monthly drip for annual subscriptions" do
      user = user_fixture()

      event = %Event{
        type: :"subscription.updated",
        actor_id: user.id,
        data: %{plan: :advanced, billing_period: :annual}
      }

      assert {:ok, :annual_suppressed} = Credits.grant_monthly_allowance_for_event(event)
      # No drip — the annual lump is granted on the purchase path, not here.
      assert Credits.balance(user.id) == 0
    end

    test "suppresses for an annual billing_period sent as a string" do
      user = user_fixture()

      event = %Event{
        type: :"subscription.updated",
        actor_id: user.id,
        data: %{"plan" => "advanced", "billing_period" => "annual"}
      }

      assert {:ok, :annual_suppressed} = Credits.grant_monthly_allowance_for_event(event)
      assert Credits.balance(user.id) == 0
    end

    test "is idempotent — re-emitting the same month's event does not double-grant" do
      user = user_fixture()
      event = %Event{type: :"subscription.updated", actor_id: user.id, data: %{plan: :advanced}}

      assert {:ok, _} = Credits.grant_monthly_allowance_for_event(event)
      assert {:ok, :already_granted} = Credits.grant_monthly_allowance_for_event(event)
      assert Credits.balance(user.id) == 10
    end

    test "ignores events without a usable actor/plan" do
      assert :ignore =
               Credits.grant_monthly_allowance_for_event(%Event{
                 type: :"subscription.updated",
                 data: %{}
               })
    end
  end

  describe "paid vs preview buckets" do
    test "grants into separate buckets and reports each balance" do
      user = user_fixture()
      {:ok, _} = Credits.grant(user.id, 3, "subscription", :paid)
      {:ok, _} = Credits.grant(user.id, 2, "promo", :preview)

      assert Credits.balance(user.id, :paid) == 3
      assert Credits.balance(user.id, :preview) == 2
      assert Credits.balance(user.id) == 5
    end

    test "a full review only spends paid credits, never preview credits" do
      user = user_fixture()
      {:ok, _} = Credits.grant(user.id, 2, "promo", :preview)

      # Preview credits don't make a full review affordable.
      assert {:error, :insufficient_credits} = Credits.charge_for_proofreading(user.id)
      assert Credits.balance(user.id, :preview) == 2
    end

    test "charge_for_preview spends a preview credit, down to the last" do
      user = user_fixture()
      {:ok, _} = Credits.grant(user.id, 2, "promo", :preview)

      assert {:ok, event, _crossed?} = Credits.charge_for_preview(user.id)
      assert event.amount == -1
      assert Credits.balance(user.id, :preview) == 1

      {:ok, _, _} = Credits.charge_for_preview(user.id)
      assert {:error, :insufficient_credits} = Credits.charge_for_preview(user.id)
    end
  end

  describe "apply_event/2 — composable campaigns" do
    test "signup grants an academic/gov writer one preview credit, idempotently" do
      user = user_fixture()
      Credits.apply_event(:signup, %{user_id: user.id, email: "scholar@stanford.edu"})
      Credits.apply_event(:signup, %{user_id: user.id, email: "scholar@stanford.edu"})
      assert Credits.balance(user.id, :preview) == 1
    end

    test "signup grants NO free credit to a non-academic email (must use a referral)" do
      user = user_fixture()
      Credits.apply_event(:signup, %{user_id: user.id, email: "writer@gmail.com"})
      assert Credits.balance(user.id, :preview) == 0
    end

    test "an accepted referral grants the referrer AND the (any-domain) referee a preview credit" do
      referrer = user_fixture()
      referee = user_fixture()

      Credits.apply_event(:referral_accepted, %{referrer_id: referrer.id, referee_id: referee.id})

      assert Credits.balance(referrer.id, :preview) == 1
      assert Credits.balance(referee.id, :preview) == 1
    end

    test "a self-referral grants nothing (guard blocks it)" do
      user = user_fixture()
      Credits.apply_event(:referral_accepted, %{referrer_id: user.id, referee_id: user.id})
      assert Credits.balance(user.id, :preview) == 0
    end

    test "the same referral is rewarded only once (once_per filter)" do
      referrer = user_fixture()
      referee = user_fixture()
      ctx = %{referrer_id: referrer.id, referee_id: referee.id}

      Credits.apply_event(:referral_accepted, ctx)
      Credits.apply_event(:referral_accepted, ctx)

      assert Credits.balance(referrer.id, :preview) == 1
    end

    test "a referred purchase upgrades the referrer's preview credit to paid" do
      referrer = user_fixture()
      referee = user_fixture()
      Credits.apply_event(:referral_accepted, %{referrer_id: referrer.id, referee_id: referee.id})
      assert Credits.balance(referrer.id, :preview) == 1

      Credits.apply_event(:referral_purchase, %{referrer_id: referrer.id, referee_id: referee.id})

      assert Credits.balance(referrer.id, :preview) == 0
      assert Credits.balance(referrer.id, :paid) == 1
    end
  end

  describe "convert/6 balance safety" do
    test "refuses to convert more than the source bucket holds" do
      user = user_fixture()
      {:ok, _} = Credits.grant(user.id, 1, "promo", :preview)

      assert {:error, :insufficient_credits} =
               Credits.convert(user.id, :preview, :paid, 2, "upgrade")

      # nothing minted, source untouched
      assert Credits.balance(user.id, :preview) == 1
      assert Credits.balance(user.id, :paid) == 0
    end

    test "converts when the source bucket has enough" do
      user = user_fixture()
      {:ok, _} = Credits.grant(user.id, 2, "promo", :preview)

      assert {:ok, _event} = Credits.convert(user.id, :preview, :paid, 2, "upgrade")
      assert Credits.balance(user.id, :preview) == 0
      assert Credits.balance(user.id, :paid) == 2
    end

    test "a referred purchase with no earned preview credit mints nothing" do
      referrer = user_fixture()
      referee = user_fixture()

      # No referral_accepted first, so the referrer has no preview credit to upgrade.
      Credits.apply_event(:referral_purchase, %{referrer_id: referrer.id, referee_id: referee.id})

      assert Credits.balance(referrer.id, :paid) == 0
      assert Credits.balance(referrer.id, :preview) == 0
    end
  end

  describe "notify_granted/1" do
    test "emails the recipient when they receive a free credit" do
      user = user_fixture()

      Credits.notify_granted(%{
        user_id: user.id,
        amount: 1,
        kind: :preview,
        reason: "signup_bonus"
      })

      assert_email_sent()
    end

    test "ignores charges (negative amounts)" do
      user = user_fixture()

      assert Credits.notify_granted(%{
               user_id: user.id,
               amount: -1,
               kind: :paid,
               reason: "proofreading"
             }) == :ok

      assert_no_email_sent()
    end
  end
end
