defmodule PerfectPaper.Billing.PortalTest do
  # async: false — the Stripe describe sets the global billing_provider + config.
  use PerfectPaper.DataCase, async: false

  alias PerfectPaper.{Billing, Repo}
  alias PerfectPaper.Billing.Subscription

  import PerfectPaper.AccountsFixtures

  defp seed_subscription(user, customer_id) do
    {:ok, sub} =
      %Subscription{}
      |> Subscription.sync_changeset(%{
        user_id: user.id,
        plan: :professional,
        status: :active,
        provider_customer_id: customer_id
      })
      |> Repo.insert()

    sub
  end

  describe "stub provider" do
    test "portal is unsupported" do
      refute Billing.portal_supported?()
    end

    test "billing_portal_url returns :portal_unsupported" do
      user = user_fixture()
      seed_subscription(user, "cus_x")

      assert {:error, :portal_unsupported} =
               Billing.billing_portal_url(user, "https://app/billing")
    end
  end

  describe "Stripe provider" do
    setup do
      prev_p = Application.get_env(:perfect_paper, :billing_provider)
      prev_s = Application.get_env(:perfect_paper, :stripe)
      Application.put_env(:perfect_paper, :billing_provider, PerfectPaper.Billing.StripeAdapter)
      Application.put_env(:perfect_paper, :stripe, api_key: "sk_test_x")

      on_exit(fn ->
        Application.put_env(:perfect_paper, :billing_provider, prev_p)
        Application.put_env(:perfect_paper, :stripe, prev_s)
      end)

      :ok
    end

    test "portal is supported" do
      assert Billing.portal_supported?()
    end

    test "creates a portal session for the user's customer and returns the url" do
      user = user_fixture()
      seed_subscription(user, "cus_real")

      Req.Test.stub(:stripe, fn conn ->
        assert conn.request_path == "/v1/billing_portal/sessions"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "cus_real"

        Req.Test.json(conn, %{
          "id" => "bps_1",
          "url" => "https://billing.stripe.com/p/session/bps_1"
        })
      end)

      assert {:ok, "https://billing.stripe.com/p/session/bps_1"} =
               Billing.billing_portal_url(user, "https://app/billing",
                 req_opts: [plug: {Req.Test, :stripe}]
               )
    end

    test "a user with no subscription has no customer to manage" do
      user = user_fixture()
      assert {:error, :no_customer} = Billing.billing_portal_url(user, "https://app/billing")
    end
  end
end
