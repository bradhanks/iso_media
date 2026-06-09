defmodule PerfectPaper.Billing.Prices do
  @moduledoc """
  Pure configuration module for PerfectPaper's product catalogue.

  Prices and features live here — not in the database — so changing the
  catalogue requires a code deploy, not a migration.

  There are two product families:

  - `subscriptions/0` — recurring monthly plans (`:subscription` mode)
  - `credit_packs/0` — one-time review bundles (`:payment` mode)

  Use `list/0` for any code that previously consumed the legacy plan list;
  it delegates to `subscriptions/0`. Use `price_label/1` to format a legacy
  product map for display.
  """

  @type legacy_product :: %{
          plan: :free | :standard | :pro,
          price_cents: non_neg_integer(),
          interval: :month | :year,
          features: [String.t()]
        }

  @type plan_map :: %{
          key: atom(),
          name: String.t(),
          price_label: String.t(),
          cadence: String.t(),
          tagline: String.t() | nil,
          badge: String.t() | nil,
          savings: String.t() | nil,
          features: [String.t()],
          popular?: boolean(),
          mode: :payment | :subscription,
          cta: String.t(),
          price_env: String.t()
        }

  # Shared trailing features for all subscription plans
  @subscription_trailing_features [
    "$10 off additional reviews beyond your monthly allowance",
    "Cancel anytime — no commitment",
    "Unused credits roll over each month"
  ]

  @doc """
  Returns all available subscription products in ascending price order.

  Delegates to `subscriptions/0` for callers that previously used the legacy
  plan list. Kept for backward compatibility.
  """
  @spec list() :: [plan_map()]
  def list, do: subscriptions()

  @doc """
  Formats a legacy product's price for display, e.g. `"Free"`, `"$19/mo"`, `"$49/mo"`.
  """
  @spec price_label(legacy_product()) :: String.t()
  def price_label(%{price_cents: 0}), do: "Free"

  def price_label(%{price_cents: cents, interval: interval}) do
    dollars = cents |> div(100)
    suffix = if interval == :year, do: "/yr", else: "/mo"
    "$#{dollars}#{suffix}"
  end

  @doc """
  Returns the three one-time credit pack offerings in ascending price order.

  Each map carries all keys needed to render a pricing card and resolve the
  Stripe price ID at checkout time via `:price_env`.
  """
  @spec credit_packs() :: [plan_map()]
  def credit_packs do
    [
      %{
        key: :pack_3,
        name: "3 full reviews",
        price_label: "$149.99",
        cadence: "project package",
        tagline: nil,
        badge: nil,
        savings: nil,
        popular?: true,
        mode: :payment,
        cta: "Buy now",
        price_env: "STRIPE_PRICE_PACK_3",
        list_cents: 14999,
        # Volume multiplier in basis points (10_000 = no volume discount). Only the
        # largest bundle (:pack_12) is discounted; the rest are flat per-review.
        volume_bps: 10_000,
        features: [
          "Includes all PerfectPaper suggestions on each review",
          "Three full reviews to catch issues introduced while revising a draft, or for other papers",
          "No subscription required"
        ]
      },
      %{
        key: :pack_6,
        name: "6 full reviews",
        price_label: "$299.99",
        cadence: "extended package",
        tagline: nil,
        badge: nil,
        savings: nil,
        popular?: false,
        mode: :payment,
        cta: "Buy now",
        price_env: "STRIPE_PRICE_PACK_6",
        list_cents: 29999,
        volume_bps: 10_000,
        features: [
          "Everything in the 3-pack, with twice the reviews",
          "Use credits on the same manuscript at different stages or across papers",
          "No subscription required"
        ]
      },
      %{
        key: :pack_12,
        name: "12 full reviews",
        price_label: "$599.99",
        cadence: "professional package",
        tagline: nil,
        badge: nil,
        savings: "17% off — best value",
        popular?: false,
        mode: :payment,
        cta: "Buy now",
        price_env: "STRIPE_PRICE_PACK_12",
        list_cents: 59999,
        # 17% off — the only bundle with a volume discount.
        volume_bps: 8_300,
        features: [
          "Our best per-review value — 17% off",
          "Twelve full reviews for a busy term or a lab",
          "No subscription required"
        ]
      }
    ]
  end

  @doc """
  The inline single-credit top-up (\"buy one more review\" when out of credits).

  Not a pricing-bundle card — `credit_packs/0` returns only the three bundles, so
  the home/billing pricing grids stay to actual cards. Priced through the same
  band math as the packs with no volume discount (`volume_bps: 10_000`).
  """
  @spec credit_single() :: plan_map()
  def credit_single do
    %{
      key: :credit_single,
      name: "1 full review",
      price_label: "$49.99",
      cadence: "one-time top-up",
      tagline: "Buy one more review",
      badge: nil,
      savings: nil,
      popular?: false,
      mode: :payment,
      cta: "Buy a review",
      price_env: "STRIPE_PRICE_CREDIT_SINGLE",
      list_cents: 4999,
      volume_bps: 10_000,
      features: [
        "A single full review — no subscription",
        "Includes all PerfectPaper suggestions"
      ]
    }
  end

  @doc """
  Returns the three recurring subscription plans in ascending price order.

  Each map carries all keys needed to render a pricing card and resolve the
  Stripe price ID at checkout time via `:price_env`.
  """
  @spec subscriptions() :: [plan_map()]
  def subscriptions do
    [
      %{
        key: :starter,
        name: "Starter",
        price_label: "$40",
        cadence: "1 full review per month",
        tagline: "Perfect for occasional writers",
        badge: nil,
        savings: nil,
        popular?: false,
        mode: :subscription,
        cta: "Subscribe",
        price_env: "STRIPE_PRICE_SUB_STARTER",
        list_cents: 4000,
        features:
          [
            "Save hours of editing — PerfectPaper identifies overlooked errors in substance and style",
            "Full review in under an hour"
          ] ++ @subscription_trailing_features
      },
      %{
        key: :professional,
        name: "Professional",
        price_label: "$100",
        cadence: "3 full reviews per month",
        tagline: "Most popular",
        badge: "= $33.33 / review",
        savings: nil,
        popular?: true,
        mode: :subscription,
        cta: "Subscribe",
        price_env: "STRIPE_PRICE_SUB_PRO",
        list_cents: 10000,
        features:
          [
            "Three full reviews per month to catch new issues introduced while revising your draft",
            "Perfect for regular writers"
          ] ++ @subscription_trailing_features
      },
      %{
        key: :advanced,
        name: "Advanced",
        price_label: "$300",
        cadence: "10 full reviews per month",
        tagline: "For power users",
        badge: "= $30.00 / review",
        savings: nil,
        popular?: false,
        mode: :subscription,
        cta: "Subscribe",
        price_env: "STRIPE_PRICE_SUB_ADVANCED",
        list_cents: 30000,
        features:
          [
            "Use full reviews on the same manuscript at different stages or across multiple papers",
            "Best for editors and frequent publishers"
          ] ++ @subscription_trailing_features
      }
    ]
  end
end
