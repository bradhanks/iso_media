defmodule PerfectPaper.Billing.StripeAdapter do
  @moduledoc """
  `Billing.Provider` adapter backed by Stripe (via `StripeClient`).

  The anti-corruption boundary: Stripe's string-keyed JSON, price ids, and event
  shapes never leak past this module — every public function returns atom-keyed
  maps matching our schema fields. Selected per-env with:

      config :perfect_paper, :billing_provider, PerfectPaper.Billing.StripeAdapter

  Webhooks are the **source of truth**: `verify_webhook/2` authenticates the raw
  body, `translate_event/1` turns a raw Stripe event into a provider-agnostic
  `webhook_event` (`:subscription_upserted` / `:subscription_canceled` /
  `:checkout_completed`), which the `Billing` context reconciles into the local
  `Subscription` + credit grants.
  """
  @behaviour PerfectPaper.Billing.Provider

  alias PerfectPaper.Billing.StripeClient

  # ── Customers ───────────────────────────────────────────────────────────────

  @impl true
  def create_customer(attrs) do
    params =
      %{email: attrs[:email]}
      |> maybe_put(:name, attrs[:name])
      # Echo the user id into metadata so the subscription webhook can map the
      # Stripe customer back to our user without a separate lookup.
      |> maybe_put_metadata(attrs[:user_id])

    case StripeClient.create_customer(params, req_opts(attrs)) do
      {:ok, %{"id" => id}} -> {:ok, %{provider_customer_id: id}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Subscriptions ───────────────────────────────────────────────────────────

  @impl true
  def create_subscription(attrs) do
    with price when is_binary(price) <- price_id(attrs[:plan], attrs[:cadence] || :monthly) do
      params = %{
        customer: attrs[:provider_customer_id],
        items: [%{price: price}],
        # Surface collection failures synchronously instead of leaving the sub
        # stuck in `incomplete`.
        payment_behavior: "error_if_incomplete",
        metadata: subscription_metadata(attrs)
      }

      case StripeClient.create_subscription(params, req_opts(attrs)) do
        {:ok, sub} -> {:ok, subscription_attrs(sub)}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :unknown_price}
    end
  end

  @impl true
  def cancel_subscription(provider_subscription_id) do
    case StripeClient.cancel_subscription(provider_subscription_id) do
      {:ok, _sub} -> {:ok, %{status: :canceled}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Checkout / portal ───────────────────────────────────────────────────────

  @impl true
  def create_checkout_session(attrs) do
    mode = attrs[:mode] || "subscription"
    # Resolve the Stripe price id from our domain plan + cadence (price ids stay
    # inside the adapter), unless the caller passed one explicitly.
    price = attrs[:price_id] || price_id(attrs[:plan], attrs[:cadence])

    with price when is_binary(price) <- price do
      params =
        %{
          customer: attrs[:provider_customer_id],
          mode: mode,
          line_items: [%{price: price, quantity: 1}],
          # Echo metadata onto the resulting subscription so its webhook self-describes.
          metadata: attrs[:metadata] || %{}
        }
        |> Map.merge(ui_params(attrs))
        |> maybe_put(:subscription_data, subscription_data(mode, attrs[:metadata]))

      case StripeClient.create_checkout_session(params, req_opts(attrs)) do
        {:ok, %{"id" => id} = session} ->
          {:ok,
           %{session_id: id}
           |> maybe_put(:checkout_url, session["url"])
           |> maybe_put(:client_secret, session["client_secret"])}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :unknown_price}
    end
  end

  @impl true
  def create_portal_session(attrs) do
    params = %{customer: attrs[:provider_customer_id], return_url: attrs[:return_url]}

    case StripeClient.create_portal_session(params, req_opts(attrs)) do
      {:ok, %{"url" => url}} -> {:ok, %{portal_url: url}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Webhooks ────────────────────────────────────────────────────────────────

  @impl true
  def verify_webhook(raw_body, signature) do
    secret = :perfect_paper |> Application.get_env(:stripe, []) |> Keyword.get(:webhook_secret)
    StripeClient.verify_webhook(raw_body, signature, secret)
  end

  @impl true
  def translate_event(%{"id" => id, "type" => type, "data" => %{"object" => object}}) do
    case type do
      "customer.subscription.created" ->
        {:ok, event(id, type, :subscription_upserted, subscription_attrs(object))}

      "customer.subscription.updated" ->
        {:ok, event(id, type, :subscription_upserted, subscription_attrs(object))}

      "customer.subscription.deleted" ->
        {:ok,
         event(id, type, :subscription_canceled, %{
           provider_subscription_id: object["id"],
           provider_customer_id: object["customer"],
           user_id: metadata(object)["user_id"]
         })}

      "checkout.session.completed" ->
        {:ok,
         event(id, type, :checkout_completed, %{
           provider_customer_id: object["customer"],
           provider_subscription_id: object["subscription"],
           user_id: metadata(object)["user_id"],
           # "payment" = a one-time pack purchase (grant credits); "subscription" =
           # a sub checkout (no-op here — its subscription.created event does the work).
           mode: object["mode"],
           metadata: metadata(object)
         })}

      _ ->
        {:error, :unhandled_event}
    end
  end

  def translate_event(_), do: {:error, :unhandled_event}

  # ── Translation helpers ─────────────────────────────────────────────────────

  defp event(id, type, action, data),
    do: %{event_id: id, event_type: type, action: action, data: data}

  # Stripe subscription object → atom-keyed attrs matching our Subscription fields.
  defp subscription_attrs(sub) do
    meta = metadata(sub)
    price = sub |> get_in(["items", "data"]) |> List.wrap() |> List.first() |> price_of()

    %{
      provider_subscription_id: sub["id"],
      provider_customer_id: sub["customer"],
      user_id: meta["user_id"],
      plan: atomize(meta["plan"]),
      billing_period: billing_period(meta["cadence"], price),
      status: map_status(sub["status"]),
      current_period_end: unix_to_datetime(sub["current_period_end"])
    }
  end

  defp price_of(%{"price" => price}), do: price
  defp price_of(_), do: nil

  defp metadata(%{"metadata" => meta}) when is_map(meta), do: meta
  defp metadata(_), do: %{}

  # Cadence from explicit metadata first, else the price's recurring interval.
  defp billing_period("annual", _), do: :annual
  defp billing_period("monthly", _), do: :monthly
  defp billing_period(_, %{"recurring" => %{"interval" => "year"}}), do: :annual
  defp billing_period(_, _), do: :monthly

  # Stripe status → our enum. Trialing counts as active; anything not clearly
  # good-standing or canceled is treated as past_due (recoverable).
  defp map_status(s) when s in ["active", "trialing"], do: :active
  defp map_status("canceled"), do: :canceled
  defp map_status(_), do: :past_due

  defp atomize(nil), do: nil
  defp atomize(s) when is_binary(s), do: String.to_existing_atom(s)

  defp unix_to_datetime(nil), do: nil

  defp unix_to_datetime(unix) when is_integer(unix),
    do: unix |> DateTime.from_unix!() |> DateTime.truncate(:second)

  # ── Param helpers ───────────────────────────────────────────────────────────

  defp subscription_metadata(attrs) do
    %{}
    |> maybe_put("user_id", attrs[:user_id])
    |> maybe_put("plan", attrs[:plan] && to_string(attrs[:plan]))
    |> maybe_put("cadence", attrs[:cadence] && to_string(attrs[:cadence]))
  end

  # subscription_data carries metadata onto the created subscription (only for
  # subscription-mode checkout; one-time payments have no subscription).
  defp subscription_data("subscription", metadata)
       when is_map(metadata) and map_size(metadata) > 0,
       do: %{metadata: metadata}

  defp subscription_data(_mode, _metadata), do: nil

  defp price_id(product, cadence) do
    key = if cadence, do: "#{product}_#{cadence}", else: to_string(product)

    :perfect_paper
    |> Application.get_env(:stripe, [])
    |> Keyword.get(:price_ids, %{})
    |> Map.get(key)
  end

  # Hosted vs embedded session params. Embedded mounts Stripe's iframe in-app and
  # returns a `client_secret` (with a single `return_url`); hosted redirects to
  # Stripe and returns a `url` (with success/cancel URLs).
  defp ui_params(%{ui_mode: "embedded"} = attrs),
    do: %{ui_mode: "embedded", return_url: attrs[:return_url] || attrs[:success_url]}

  defp ui_params(attrs),
    do: %{success_url: attrs[:success_url], cancel_url: attrs[:cancel_url]}

  # Pass-through request options (e.g. a Req.Test `plug:` for tests, or an
  # idempotency_key). Production callers omit it → no extra opts.
  defp req_opts(attrs), do: attrs[:req_opts] || []

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_metadata(params, nil), do: params
  defp maybe_put_metadata(params, user_id), do: Map.put(params, :metadata, %{user_id: user_id})
end
