defmodule PerfectPaper.Billing.StripeClientTest do
  # async: false — the HTTP cases set the global :stripe api_key config.
  use ExUnit.Case, async: false

  alias PerfectPaper.Billing.StripeClient

  describe "verify_webhook/3" do
    setup do
      secret = "whsec_test_secret"
      payload = ~s({"id":"evt_1","type":"customer.subscription.updated"})
      {:ok, secret: secret, payload: payload}
    end

    defp sign(payload, secret, ts) do
      sig = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{payload}") |> Base.encode16(case: :lower)
      "t=#{ts},v1=#{sig}"
    end

    test "accepts a correctly-signed, fresh payload", %{secret: secret, payload: payload} do
      header = sign(payload, secret, System.system_time(:second))
      assert {:ok, %{"id" => "evt_1"}} = StripeClient.verify_webhook(payload, header, secret)
    end

    test "rejects a payload signed with the wrong secret", %{secret: secret, payload: payload} do
      header = sign(payload, "whsec_wrong", System.system_time(:second))
      assert {:error, :invalid_signature} = StripeClient.verify_webhook(payload, header, secret)
    end

    test "rejects a tampered body", %{secret: secret, payload: payload} do
      header = sign(payload, secret, System.system_time(:second))

      assert {:error, :invalid_signature} =
               StripeClient.verify_webhook(payload <> " ", header, secret)
    end

    test "rejects a stale timestamp (>5 min)", %{secret: secret, payload: payload} do
      header = sign(payload, secret, System.system_time(:second) - 600)
      assert {:error, :invalid_signature} = StripeClient.verify_webhook(payload, header, secret)
    end

    test "rejects a malformed header without crashing", %{secret: secret, payload: payload} do
      assert {:error, :invalid_signature} =
               StripeClient.verify_webhook(payload, "garbage", secret)

      assert {:error, :invalid_signature} = StripeClient.verify_webhook(payload, "", secret)
    end

    test "a wrong-length forged v1 yields :invalid_signature, not a crash", %{
      secret: secret,
      payload: payload
    } do
      header = "t=#{System.system_time(:second)},v1=abcd"
      assert {:error, :invalid_signature} = StripeClient.verify_webhook(payload, header, secret)
    end
  end

  describe "HTTP requests (Req.Test plug)" do
    setup do
      prev = Application.get_env(:perfect_paper, :stripe)

      Application.put_env(:perfect_paper, :stripe,
        api_key: "sk_test_x",
        webhook_secret: "whsec_x"
      )

      on_exit(fn -> Application.put_env(:perfect_paper, :stripe, prev) end)
      :ok
    end

    test "create_customer posts form params and returns the parsed body" do
      Req.Test.stub(:stripe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "email=a%40b.c"
        assert {"stripe-version", "2026-05-27.dahlia"} in conn.req_headers
        Req.Test.json(conn, %{"id" => "cus_123", "email" => "a@b.c"})
      end)

      assert {:ok, %{"id" => "cus_123"}} =
               StripeClient.create_customer(%{email: "a@b.c"}, plug: {Req.Test, :stripe})
    end

    test "maps a Stripe error body to {:error, message}" do
      Req.Test.stub(:stripe, fn conn ->
        conn
        |> Plug.Conn.put_status(402)
        |> Req.Test.json(%{"error" => %{"message" => "Your card was declined."}})
      end)

      assert {:error, "Your card was declined."} =
               StripeClient.create_subscription(%{customer: "cus_1"}, plug: {Req.Test, :stripe})
    end
  end
end
