defmodule PerfectPaper.Billing.Provider do
  @moduledoc """
  Behaviour that every payments-provider adapter must implement.

  Adapters return **atom-keyed maps whose keys match `Subscription` schema fields**
  so the Billing context can pass the result directly into a changeset without
  any further mapping:

      {:ok, %{provider_customer_id: "cus_..."}}
      {:ok, %{provider_subscription_id: "sub_...", status: :active}}
      {:ok, %{status: :canceled}}

  The Billing context selects the adapter at runtime via:

      Application.get_env(:perfect_paper, :billing_provider)

  No vendor-specific keys, HTTP clients, or error shapes should leak past an
  adapter implementation.
  """

  @doc """
  Creates a customer record in the payments provider.

  Accepts a map of user attributes (e.g. `%{email: ..., name: ...}`) and returns
  an atom-keyed map containing at least `provider_customer_id`.
  """
  @callback create_customer(attrs :: map()) ::
              {:ok, %{required(:provider_customer_id) => String.t()}} | {:error, term()}

  @doc """
  Creates a subscription for an existing provider customer.

  Accepts a map with at least `provider_customer_id` and `plan`, and returns an
  atom-keyed map containing at least `provider_subscription_id` and `status`.
  """
  @callback create_subscription(attrs :: map()) ::
              {:ok,
               %{
                 required(:provider_subscription_id) => String.t(),
                 required(:status) => :active | :canceled | :past_due
               }}
              | {:error, term()}

  @doc """
  Cancels an active subscription identified by its provider-side ID.

  Returns an atom-keyed map containing at least `status: :canceled`.
  """
  @callback cancel_subscription(provider_subscription_id :: String.t()) ::
              {:ok, %{required(:status) => :canceled}} | {:error, term()}

  # ── Hosted-provider extensions (Stripe et al.) ──────────────────────────────
  # Optional so the stub stays conformant without them; the Stripe adapter
  # implements all four. A "checkout session" hands payment-card collection to the
  # provider's hosted/embedded UI, and the provider confirms the result asyncly
  # via a signed webhook — which is the source of truth, reconciled into our
  # `Subscription`/`Credits` state.

  @typedoc """
  A provider-agnostic webhook event, translated from the raw vendor payload.
  `event_id` dedups retries; `action` keys the reconciliation branch.
  """
  @type webhook_event :: %{
          event_id: String.t(),
          event_type: String.t(),
          action: atom(),
          data: map()
        }

  @doc """
  Creates a hosted or embedded checkout session for a subscription or one-time
  purchase. `attrs` carries at least the customer id, mode, the provider price id,
  return/success URLs, and metadata (e.g. `user_id`) the webhook will echo back.
  Returns the redirect `checkout_url` (hosted) and/or `client_secret` (embedded)
  plus the `session_id`.
  """
  @callback create_checkout_session(attrs :: map()) ::
              {:ok,
               %{
                 optional(:checkout_url) => String.t(),
                 optional(:client_secret) => String.t(),
                 required(:session_id) => String.t()
               }}
              | {:error, term()}

  @doc "Creates a self-service billing-portal session. Returns `portal_url`."
  @callback create_portal_session(attrs :: map()) ::
              {:ok, %{required(:portal_url) => String.t()}} | {:error, term()}

  @doc """
  Verifies a webhook signature over the **raw** request body and returns the raw
  (untranslated) provider event. The raw body is required — a parsed body breaks
  the signature.
  """
  @callback verify_webhook(raw_body :: binary(), signature :: binary()) ::
              {:ok, raw_event :: map()} | {:error, :invalid_signature}

  @doc "Translates a raw provider event into a domain `webhook_event`, or `:unhandled_event`."
  @callback translate_event(raw_event :: map()) ::
              {:ok, webhook_event()} | {:error, :unhandled_event}

  @optional_callbacks create_checkout_session: 1,
                      create_portal_session: 1,
                      verify_webhook: 2,
                      translate_event: 1
end
