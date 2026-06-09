defmodule PerfectPaper.Billing.CheckoutTest do
  # async: false — the Stripe describe sets the global billing_provider + config.
  use PerfectPaper.DataCase, async: false

  alias PerfectPaper.Billing
  alias PerfectPaper.Billing.Subscription

  import PerfectPaper.AccountsFixtures

  describe "start_checkout/4 — stub provider (synchronous)" do
    test "falls back to synchronous subscribe (no hosted checkout)" do
      user = user_fixture()

      assert {:ok, {:subscribed, %Subscription{} = sub}} =
               Billing.start_checkout(user, :starter, :monthly, ip_country: "US")

      assert sub.plan == :starter
      assert sub.billing_period == :monthly
    end

    test "rejects a non-user (org/group) context" do
      assert {:error, :org_purchase_unsupported} =
               Billing.start_checkout(%{id: "org-1"}, :starter, :monthly, [])
    end
  end

  describe "start_pack_checkout/4 — stub (synchronous grant)" do
    test "grants the bundle's review credits and reports the count" do
      user = user_fixture()

      assert {:ok, {:granted, 3}} =
               Billing.start_pack_checkout(user, :pack_3, 3, ip_country: "US")

      assert PerfectPaper.Credits.balance(user.id) == 3
      # And it recorded a pricing-decision audit.
      assert [_audit] = Billing.list_pricing_decisions(user_id: user.id)
    end

    test "rejects a non-user" do
      assert {:error, :org_purchase_unsupported} =
               Billing.start_pack_checkout(%{id: "x"}, :pack_3, 3, [])
    end
  end

  describe "start_checkout/4 — embedded checkout UI" do
    setup do
      prev_p = Application.get_env(:perfect_paper, :billing_provider)
      prev_s = Application.get_env(:perfect_paper, :stripe)
      Application.put_env(:perfect_paper, :billing_provider, PerfectPaper.Billing.StripeAdapter)

      Application.put_env(:perfect_paper, :stripe,
        api_key: "sk_test_x",
        publishable_key: "pk_test_x",
        checkout_ui: :embedded,
        price_ids: %{"starter_monthly" => "price_starter_m"}
      )

      on_exit(fn ->
        Application.put_env(:perfect_paper, :billing_provider, prev_p)
        Application.put_env(:perfect_paper, :stripe, prev_s)
      end)

      :ok
    end

    test "returns a client_secret to mount in-app (no redirect url)" do
      user = user_fixture()

      Req.Test.stub(:stripe, fn conn ->
        case conn.request_path do
          "/v1/customers" ->
            Req.Test.json(conn, %{"id" => "cus_e"})

          "/v1/checkout/sessions" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert body =~ "ui_mode=embedded"
            assert body =~ "return_url"
            Req.Test.json(conn, %{"id" => "cs_e", "client_secret" => "cs_secret_123"})
        end
      end)

      assert {:ok, {:embedded, "cs_secret_123"}} =
               Billing.start_checkout(user, :starter, :monthly,
                 success_url: "https://app/billing/success",
                 req_opts: [plug: {Req.Test, :stripe}]
               )
    end
  end

  describe "start_checkout/4 — Stripe double-subscription guards" do
    setup do
      prev_p = Application.get_env(:perfect_paper, :billing_provider)
      prev_s = Application.get_env(:perfect_paper, :stripe)
      Application.put_env(:perfect_paper, :billing_provider, PerfectPaper.Billing.StripeAdapter)

      Application.put_env(:perfect_paper, :stripe,
        api_key: "sk_test_x",
        price_ids: %{"starter_monthly" => "price_starter_m"}
      )

      on_exit(fn ->
        Application.put_env(:perfect_paper, :billing_provider, prev_p)
        Application.put_env(:perfect_paper, :stripe, prev_s)
      end)

      :ok
    end

    defp seed_sub(user, status, plan) do
      {:ok, sub} =
        %Subscription{}
        |> Subscription.sync_changeset(%{
          user_id: user.id,
          plan: plan,
          status: status,
          provider_customer_id: "cus_x"
        })
        |> PerfectPaper.Repo.insert()

      sub
    end

    test "an active sub on the same plan is rejected (no second subscription)" do
      user = user_fixture()
      seed_sub(user, :active, :starter)
      assert {:error, :already_subscribed} = Billing.start_checkout(user, :starter, :monthly, [])
    end

    test "an active sub on a different plan routes to the portal (plan change)" do
      user = user_fixture()
      seed_sub(user, :active, :starter)

      assert {:error, :change_plan_in_portal} =
               Billing.start_checkout(user, :professional, :monthly, [])
    end

    test "a past_due sub routes to payment recovery, not a new checkout" do
      user = user_fixture()
      seed_sub(user, :past_due, :starter)
      assert {:error, :recover_in_portal} = Billing.start_checkout(user, :starter, :monthly, [])
    end

    test "a canceled sub may start a fresh checkout" do
      user = user_fixture()
      seed_sub(user, :canceled, :starter)

      Req.Test.stub(:stripe, fn conn ->
        assert conn.request_path == "/v1/checkout/sessions"
        Req.Test.json(conn, %{"id" => "cs_x", "url" => "https://checkout.stripe.com/c/pay/cs_x"})
      end)

      assert {:ok, {:checkout, _url}} =
               Billing.start_checkout(user, :starter, :monthly,
                 req_opts: [plug: {Req.Test, :stripe}]
               )
    end
  end

  describe "get_or_create_customer/2 (stub)" do
    test "reuses the customer id already on the user's subscription" do
      user = user_fixture()
      {:ok, _} = Billing.subscribe(user, :starter, :monthly, "US", "US", [])
      sub = Billing.get_subscription_for_user(user.id)

      assert {:ok, cid} = Billing.get_or_create_customer(user)
      assert cid == sub.provider_customer_id
    end

    test "creates a customer for a user with no subscription" do
      user = user_fixture()
      assert {:ok, cid} = Billing.get_or_create_customer(user)
      assert String.starts_with?(cid, "cus_stub_")
    end
  end

  describe "start_checkout/4 — Stripe provider (hosted redirect)" do
    setup do
      prev_p = Application.get_env(:perfect_paper, :billing_provider)
      prev_s = Application.get_env(:perfect_paper, :stripe)

      Application.put_env(:perfect_paper, :billing_provider, PerfectPaper.Billing.StripeAdapter)

      Application.put_env(:perfect_paper, :stripe,
        api_key: "sk_test_x",
        price_ids: %{"starter_monthly" => "price_starter_m", "pack_3" => "price_pack_3"}
      )

      on_exit(fn ->
        Application.put_env(:perfect_paper, :billing_provider, prev_p)
        Application.put_env(:perfect_paper, :stripe, prev_s)
      end)

      :ok
    end

    test "creates a customer + checkout session and returns the redirect url" do
      user = user_fixture()

      Req.Test.stub(:stripe, fn conn ->
        case conn.request_path do
          "/v1/customers" ->
            Req.Test.json(conn, %{"id" => "cus_new"})

          "/v1/checkout/sessions" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            # Resolves the price id from plan+cadence and targets the new customer.
            assert body =~ "price_starter_m"
            assert body =~ "cus_new"
            # Echoes user_id into subscription metadata for webhook round-trip.
            assert body =~ "user_id"

            Req.Test.json(conn, %{
              "id" => "cs_1",
              "url" => "https://checkout.stripe.com/c/pay/cs_1"
            })
        end
      end)

      assert {:ok, {:checkout, "https://checkout.stripe.com/c/pay/cs_1"}} =
               Billing.start_checkout(user, :starter, :monthly,
                 success_url: "https://app.example/billing/success",
                 cancel_url: "https://app.example/billing",
                 req_opts: [plug: {Req.Test, :stripe}]
               )
    end

    test "a credit pack opens a one-time payment-mode checkout (no synchronous grant)" do
      user = user_fixture()

      Req.Test.stub(:stripe, fn conn ->
        case conn.request_path do
          "/v1/customers" ->
            Req.Test.json(conn, %{"id" => "cus_pack"})

          "/v1/checkout/sessions" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert body =~ "mode=payment"
            assert body =~ "price_pack_3"
            assert body =~ "credits"

            Req.Test.json(conn, %{
              "id" => "cs_p",
              "url" => "https://checkout.stripe.com/c/pay/cs_p"
            })
        end
      end)

      assert {:ok, {:checkout, "https://checkout.stripe.com/c/pay/cs_p"}} =
               Billing.start_pack_checkout(user, :pack_3, 3,
                 success_url: "https://app/success",
                 cancel_url: "https://app/billing",
                 req_opts: [plug: {Req.Test, :stripe}]
               )

      # No synchronous grant on the Stripe path — credits come via the webhook.
      assert PerfectPaper.Credits.balance(user.id) == 0
    end

    test "reuses an existing customer id instead of creating a new one" do
      user = user_fixture()
      # A *canceled* sub carrying a provider_customer_id: the guard allows a fresh
      # checkout, and the customer is reused rather than re-created.
      {:ok, _} =
        %Subscription{}
        |> Subscription.sync_changeset(%{
          user_id: user.id,
          plan: :starter,
          status: :canceled,
          provider_customer_id: "cus_existing"
        })
        |> PerfectPaper.Repo.insert()

      Req.Test.stub(:stripe, fn conn ->
        # Only the checkout endpoint should be hit — no customer creation.
        assert conn.request_path == "/v1/checkout/sessions"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "cus_existing"
        Req.Test.json(conn, %{"id" => "cs_2", "url" => "https://checkout.stripe.com/c/pay/cs_2"})
      end)

      assert {:ok, {:checkout, _url}} =
               Billing.start_checkout(user, :starter, :monthly,
                 req_opts: [plug: {Req.Test, :stripe}]
               )
    end
  end
end
