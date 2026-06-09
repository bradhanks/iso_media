defmodule PerfectPaper.Webhooks.Delivery.Worker do
  @moduledoc """
  Oban worker that delivers one webhook with a Stripe-style HMAC-SHA256 signature.

  ## Signature scheme

  For each delivery attempt a timestamp `t` (Unix seconds) is generated and the
  MAC is computed over `"<t>.<raw_body>"`:

      v1 = HMAC-SHA256(endpoint.secret, "<t>.<raw_body>")   # hex-encoded, lower-case
      X-PerfectPaper-Signature: t=<t>,v1=<v1>

  Receivers verify by:
  1. Extracting `t` and `v1` from the header.
  2. Recomputing `HMAC-SHA256(your_secret, "<t>.<raw_body>")`.
  3. Comparing (constant-time) against `v1`.
  4. Optionally rejecting deliveries where `t` is too far in the past (replay guard).

  ## Retry behaviour

  Non-2xx HTTP responses and transport errors return `{:error, reason}` so Oban
  retries automatically. The delivery row is marked `:failed` only on the final
  attempt (`attempt >= max_attempts`); otherwise it stays `:pending`.
  """

  use Oban.Worker, queue: :webhooks, max_attempts: 5

  alias PerfectPaper.Repo
  alias PerfectPaper.Webhooks.{Delivery, Endpoint, Sender}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"delivery_id" => id}, attempt: attempt, max_attempts: max}) do
    delivery = Repo.get!(Delivery, id)
    endpoint = Repo.get!(Endpoint, delivery.endpoint_id)

    raw_body = Jason.encode!(delivery.payload)
    ts = System.os_time(:second)
    sig = compute_signature(endpoint.secret, ts, raw_body)

    headers = [
      {"content-type", "application/json"},
      {"x-perfectpaper-event", delivery.event_type},
      {"x-perfectpaper-delivery", delivery.id},
      {"x-perfectpaper-signature", "t=#{ts},v1=#{sig}"}
    ]

    case Sender.deliver(endpoint.url, raw_body, headers) do
      {:ok, status} when status in 200..299 ->
        mark(delivery, %{
          status: :delivered,
          attempts: attempt,
          response_status: status,
          delivered_at: DateTime.utc_now() |> DateTime.truncate(:second),
          last_error: nil
        })

        :ok

      {:ok, status} ->
        record_failure(delivery, attempt, max, "HTTP #{status}", status)

      {:error, reason} ->
        record_failure(delivery, attempt, max, inspect(reason), nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # The endpoint secret is an opaque `whsec_`-prefixed token (see
  # Webhooks.generate_secret/0); it is used VERBATIM as the HMAC-SHA256 key.
  # Receivers must do the same — do NOT base64-decode the secret before signing.
  @spec compute_signature(String.t(), integer(), String.t()) :: String.t()
  defp compute_signature(secret, ts, raw_body) do
    :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{raw_body}")
    |> Base.encode16(case: :lower)
  end

  @spec record_failure(Delivery.t(), integer(), integer(), String.t(), integer() | nil) ::
          {:error, String.t()}
  defp record_failure(delivery, attempt, max, error_msg, response_status) do
    final? = attempt >= max

    mark(delivery, %{
      status: if(final?, do: :failed, else: :pending),
      attempts: attempt,
      response_status: response_status,
      last_error: error_msg
    })

    {:error, error_msg}
  end

  @spec mark(Delivery.t(), map()) :: Delivery.t()
  defp mark(delivery, attrs) do
    delivery
    |> Delivery.attempt_changeset(attrs)
    |> Repo.update!()
  end
end
