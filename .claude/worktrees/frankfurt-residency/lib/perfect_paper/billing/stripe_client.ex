defmodule PerfectPaper.Billing.StripeClient do
  @moduledoc """
  Thin Stripe API client over `Req` — no `stripity_stripe` dependency, so all
  vendor specifics stay inside this module + `StripeAdapter` (the anti-corruption
  boundary). Returns plain maps with **string keys** (Stripe's native JSON).

  ## Configuration

      config :perfect_paper, :stripe,
        api_key: "sk_...",
        webhook_secret: "whsec_...",
        publishable_key: "pk_..."

  ## Testing

  Every public function takes an `opts` keyword list. Pass `plug:` to inject a
  `Req.Test` stub instead of hitting Stripe:

      Req.Test.stub(:stripe, fn conn -> Req.Test.json(conn, %{"id" => "cus_x"}) end)
      StripeClient.create_customer(%{email: "a@b.c"}, plug: {Req.Test, :stripe})

  > Note: a shared `:stripe` circuit breaker (4xx-don't-trip / 5xx-trip) is a
  > planned follow-up; for now `retry: false` + a bounded `receive_timeout` cap
  > the blast radius of a hung Stripe call.
  """
  require Logger

  @base_url "https://api.stripe.com/v1"
  # Latest Stripe API version (pinned). Keep in sync with the Stripe.js channel.
  @api_version "2026-05-27.dahlia"

  @doc "True when the configured key is not a live key (sandbox/test mode)."
  @spec sandbox?() :: boolean()
  def sandbox? do
    not String.starts_with?(config(:api_key) || "", "sk_live_")
  end

  # ── Customers ───────────────────────────────────────────────────────────────

  def create_customer(params, opts \\ []), do: post("/customers", params, opts)
  def update_customer(id, params, opts \\ []), do: post("/customers/#{id}", params, opts)
  def get_customer(id, opts \\ []), do: get("/customers/#{id}", %{}, opts)

  # ── Checkout sessions ───────────────────────────────────────────────────────

  def create_checkout_session(params, opts \\ []), do: post("/checkout/sessions", params, opts)
  def get_checkout_session(id, opts \\ []), do: get("/checkout/sessions/#{id}", %{}, opts)

  # ── Billing portal ──────────────────────────────────────────────────────────

  def create_portal_session(params, opts \\ []),
    do: post("/billing_portal/sessions", params, opts)

  # ── Subscriptions ───────────────────────────────────────────────────────────

  def create_subscription(params, opts \\ []), do: post("/subscriptions", params, opts)
  def update_subscription(id, params, opts \\ []), do: post("/subscriptions/#{id}", params, opts)
  def cancel_subscription(id, opts \\ []), do: delete("/subscriptions/#{id}", opts)
  def get_subscription(id, opts \\ []), do: get("/subscriptions/#{id}", %{}, opts)

  # ── Webhook verification ────────────────────────────────────────────────────

  @doc """
  Verifies a Stripe webhook signature over the **raw** body and returns the parsed
  event. HMAC-SHA256 with constant-time compare; rejects events whose timestamp is
  more than 5 minutes from now (replay window).
  """
  @spec verify_webhook(binary(), binary(), binary()) ::
          {:ok, map()} | {:error, :invalid_signature}
  def verify_webhook(raw_body, signature_header, webhook_secret) do
    with {:ok, timestamp, signatures} <- parse_signature_header(signature_header),
         :ok <- verify_timestamp(timestamp),
         signed = "#{timestamp}.#{raw_body}",
         expected = :crypto.mac(:hmac, :sha256, webhook_secret, signed),
         true <- Enum.any?(signatures, &secure_compare(expected, &1)) do
      {:ok, Jason.decode!(raw_body)}
    else
      false -> {:error, :invalid_signature}
      {:error, _} -> {:error, :invalid_signature}
    end
  end

  # ── Webhook signature internals ─────────────────────────────────────────────

  # Constant-time compare tolerant of length mismatch: `:crypto.hash_equals/2`
  # raises on differing lengths, so a forged `v1` of the wrong byte length must
  # yield :invalid_signature (400), never a 500.
  defp secure_compare(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_compare(_a, _b), do: false

  defp parse_signature_header(header) when is_binary(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.flat_map(fn part ->
        case String.split(part, "=", parts: 2) do
          [k, v] -> [{k, v}]
          _ -> []
        end
      end)

    timestamp =
      Enum.find_value(parts, fn
        {"t", v} -> v
        _ -> nil
      end)

    signatures =
      parts
      |> Enum.filter(&match?({"v1", _}, &1))
      |> Enum.flat_map(fn {_, v} ->
        case Base.decode16(v, case: :mixed) do
          {:ok, decoded} -> [decoded]
          :error -> []
        end
      end)

    if timestamp && signatures != [], do: {:ok, timestamp, signatures}, else: {:error, :invalid}
  end

  defp parse_signature_header(_), do: {:error, :invalid}

  defp verify_timestamp(ts) do
    case Integer.parse(ts) do
      {timestamp, ""} ->
        if abs(System.system_time(:second) - timestamp) <= 300, do: :ok, else: {:error, :stale}

      _ ->
        {:error, :invalid}
    end
  end

  # ── HTTP ────────────────────────────────────────────────────────────────────

  defp get(path, params, opts) do
    protected(fn ->
      [url: @base_url <> path]
      |> maybe_put_params(params)
      |> maybe_put_plug(opts)
      |> build_req()
      |> Req.get()
      |> handle_response()
    end)
  end

  defp post(path, params, opts) do
    protected(fn ->
      [url: @base_url <> path, form: encode_form_params(params)]
      |> maybe_put_plug(opts)
      |> maybe_put_idempotency_key(opts)
      |> build_req()
      |> Req.post()
      |> handle_response()
    end)
  end

  defp delete(path, opts) do
    protected(fn ->
      [url: @base_url <> path]
      |> maybe_put_plug(opts)
      |> build_req()
      |> Req.delete()
      |> handle_response()
    end)
  end

  # Run a Stripe request through the shared circuit breaker. Client errors (4xx
  # except 429 — declined card, bad request) are tagged `{:client_error, _}` so
  # they do NOT trip the breaker (Stripe is healthy); only 5xx/429/transport
  # count. The tag is unwrapped back to the public `{:error, message}`.
  defp protected(fun) do
    PerfectPaper.Billing.CircuitBreaker.call(fun, errorable?: &errorable?/1)
    |> unwrap_client_error()
  end

  defp errorable?({:client_error, _}), do: false
  defp errorable?({:error, _}), do: true
  defp errorable?(_), do: false

  defp unwrap_client_error({:client_error, message}), do: {:error, message}
  defp unwrap_client_error(other), do: other

  defp build_req(req_opts) do
    headers = Keyword.get(req_opts, :headers, [])
    req_opts = Keyword.delete(req_opts, :headers)

    base = [
      auth: {:bearer, config!(:api_key)},
      headers: [{"stripe-version", @api_version} | headers],
      retry: false,
      receive_timeout: 15_000
    ]

    Req.new(Keyword.merge(base, req_opts))
  end

  defp maybe_put_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  defp maybe_put_idempotency_key(req_opts, opts) do
    case Keyword.get(opts, :idempotency_key) do
      nil ->
        req_opts

      key ->
        headers = Keyword.get(req_opts, :headers, [])
        Keyword.put(req_opts, :headers, [{"idempotency-key", key} | headers])
    end
  end

  defp maybe_put_params(req_opts, params) when map_size(params) == 0, do: req_opts

  defp maybe_put_params(req_opts, params),
    do: Keyword.put(req_opts, :params, encode_query_params(params))

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  # 429 is an availability signal → counts toward the breaker.
  defp handle_response({:ok, %Req.Response{status: 429, body: %{"error" => %{"message" => msg}}}}) do
    Logger.warning("Stripe API rate limited: #{msg}")
    {:error, msg}
  end

  # Other 4xx are expected client errors (declined card, bad request) — Stripe is
  # healthy, so they must NOT trip the breaker. Tagged for `errorable?/1`.
  defp handle_response(
         {:ok, %Req.Response{status: status, body: %{"error" => %{"message" => msg}}}}
       )
       when status in 400..499 do
    Logger.warning("Stripe API client error (#{status}): #{msg}")
    {:client_error, msg}
  end

  # 5xx (or any other) error body — a Stripe-side failure; counts.
  defp handle_response(
         {:ok, %Req.Response{status: status, body: %{"error" => %{"message" => msg}}}}
       ) do
    Logger.warning("Stripe API error (#{status}): #{msg}")
    {:error, msg}
  end

  defp handle_response({:ok, %Req.Response{status: status}}) do
    Logger.warning("Stripe API error (#{status})")
    {:error, "Payment service error"}
  end

  defp handle_response({:error, exception}) do
    Logger.error("Stripe request failed: #{Exception.message(exception)}")
    {:error, :stripe_request_failed}
  end

  # ── Config ──────────────────────────────────────────────────────────────────

  defp config(key), do: :perfect_paper |> Application.get_env(:stripe, []) |> Keyword.get(key)

  defp config!(key) do
    config(key) ||
      raise "Missing Stripe config: #{key}. Set config :perfect_paper, :stripe, #{key}: ..."
  end

  # ── Stripe form/query encoding (bracket notation) ───────────────────────────

  # %{items: [%{price: "p_1"}]} => [{"items[0][price]", "p_1"}]
  defp encode_form_params(params) when is_map(params) do
    params
    |> flatten_params([])
    |> Enum.map(fn {keys, value} -> {encode_key(keys), to_string(value)} end)
  end

  defp flatten_params(map, prefix) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> flatten_params(v, prefix ++ [k]) end)

  defp flatten_params(list, prefix) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} -> flatten_params(v, prefix ++ [i]) end)
  end

  defp flatten_params(value, prefix) when is_atom(value) and not is_boolean(value),
    do: [{prefix, Atom.to_string(value)}]

  defp flatten_params(value, prefix), do: [{prefix, value}]

  defp encode_key([first | rest]) do
    parts = Enum.map(rest, fn k -> ["[", to_string(k), "]"] end)
    IO.iodata_to_binary([to_string(first) | parts])
  end

  defp encode_query_params(params) when is_map(params) do
    Enum.flat_map(params, fn
      {key, value} when is_map(value) ->
        Enum.map(value, fn {k, v} -> {"#{key}[#{k}]", to_string(v)} end)

      {key, value} ->
        [{to_string(key), to_string(value)}]
    end)
  end
end
