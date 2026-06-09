defmodule PerfectPaperWeb.StripeWebhookController do
  @moduledoc """
  Inbound Stripe webhook endpoint. Thin — all verification, dedup, and
  reconciliation live in `Billing.process_stripe_webhook/2`.

  Status contract (Stripe only inspects the 2xx/non-2xx class):

    * 200 — verified + processed (or already-processed / deliberately ignored).
      A 2xx tells Stripe to stop retrying.
    * 400 — bad/forged signature. Not retried (it never becomes valid).
    * 500 — a transient processing failure; the event is left un-processed so
      Stripe's retry re-claims and reprocesses it.
  """
  use PerfectPaperWeb, :controller

  require Logger

  alias PerfectPaper.Billing

  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, _params) do
    raw_body = conn.private[:raw_body] || ""
    signature = conn |> get_req_header("stripe-signature") |> List.first() || ""

    case Billing.process_stripe_webhook(raw_body, signature) do
      {:ok, _result} ->
        send_resp(conn, 200, "ok")

      {:error, :invalid_signature} ->
        send_resp(conn, 400, "invalid signature")

      {:error, reason} ->
        Logger.error("Stripe webhook processing failed: #{inspect(reason)}")
        send_resp(conn, 500, "error")
    end
  end
end
