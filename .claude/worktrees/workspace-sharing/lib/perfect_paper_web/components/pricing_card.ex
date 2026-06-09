defmodule PerfectPaperWeb.PricingCard do
  @moduledoc "Band-aware subscription pricing card (pure function component, JS cadence toggle)."
  use PerfectPaperWeb, :html
  alias PerfectPaper.Billing.{Prices, Pricing}

  attr :plan, :atom, required: true
  attr :band, :atom, required: true
  attr :eea?, :boolean, default: false
  attr :name, :string, required: true

  @spec plan_card(map()) :: Phoenix.LiveView.Rendered.t()
  @doc "Renders a banded subscription pricing card with monthly/annual cadence variants."
  def plan_card(assigns) do
    plan_map = Enum.find(Prices.subscriptions(), &(&1.key == assigns.plan))
    p = Pricing.price_for(plan_map, assigns.band)
    assigns = assign(assigns, :p, p)

    ~H"""
    <div class="pricing-card rounded-box border border-base-300 p-6" data-plan={@plan}>
      <h3 class="font-display text-xl font-semibold">{@name}</h3>

      <div data-cadence="monthly">
        <span :if={@p.struck? and not @eea?} class="font-sans text-base-content/45 line-through">
          {Pricing.format_cents(@p.monthly_list)}
        </span>
        <span class="font-display text-2xl font-semibold">
          {Pricing.format_cents(@p.monthly_price)}
        </span>
        <span class="text-sm text-base-content/55">{gettext("/mo")}</span>
      </div>

      <div data-cadence="annual" class="hidden">
        <span class="font-sans text-base-content/45 line-through">
          {Pricing.format_cents(@p.annual_list)}
        </span>
        <span class="font-display text-2xl font-semibold">
          {Pricing.format_cents(@p.annual_price)}
        </span>
        <span class="text-sm text-base-content/55">{gettext("/yr")}</span>
      </div>
    </div>
    """
  end

  @spec cadence_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  @doc "Monthly/annual toggle button group, client-side via Phoenix.LiveView.JS."
  def cadence_toggle(assigns) do
    ~H"""
    <div class="join" role="group" aria-label={gettext("Billing period")}>
      <button
        type="button"
        class="btn btn-sm join-item"
        data-cadence-toggle="monthly"
        phx-click={
          JS.add_class("hidden", to: "[data-cadence=annual]")
          |> JS.remove_class("hidden", to: "[data-cadence=monthly]")
        }
      >
        {gettext("Monthly")}
      </button>
      <button
        type="button"
        class="btn btn-sm join-item"
        data-cadence-toggle="annual"
        phx-click={
          JS.add_class("hidden", to: "[data-cadence=monthly]")
          |> JS.remove_class("hidden", to: "[data-cadence=annual]")
        }
      >
        {gettext("Annual")}
      </button>
    </div>
    """
  end
end
