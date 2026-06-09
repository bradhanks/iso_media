defmodule PerfectPaperWeb.PricingComponents do
  @moduledoc """
  Banded subscription pricing cards with a **client-side** monthly/annual cadence
  toggle.

  Both cadences are server-rendered for every card; the toggle (a
  `Phoenix.LiveView.JS` command) flips `data-cadence` on the grid container and
  Tailwind `group-data-*` variants reveal the matching price block. This works
  identically on the dead home page and inside `billing_live` — there is no
  server round-trip and no LiveView state, so the cards never flicker on
  reconnect.

  Prices come from `Billing.Pricing.price_for/2` for the resolved display
  `band`. When the visitor is in the EU/EEA the *regional* monthly strike is
  suppressed (`eu?` — Omnibus Directive: a struck reference price must be a
  genuine prior price). The annual strike is a real two-months-free saving and
  always shows.
  """
  use PerfectPaperWeb, :html

  alias PerfectPaper.Billing.Pricing

  @doc """
  The full subscription pricing block: the cadence toggle plus one
  `plan_card/1` per plan, sharing one `data-cadence` container.
  """
  attr :plans, :list, required: true, doc: "`Billing.Prices.subscriptions/0` maps"
  attr :band, :atom, default: :a, doc: "resolved display band (`Pricing.band_key`)"
  attr :eu?, :boolean, default: false, doc: "EU/EEA visitor → suppress regional monthly strike"
  attr :register_path, :string, default: "/users/register"
  attr :class, :string, default: nil

  def pricing_table(assigns) do
    ~H"""
    <div id="pricing-grid" data-cadence="monthly" class={["group/grid", @class]}>
      <.cadence_toggle />
      <div class="mt-6 grid gap-6 md:grid-cols-3">
        <.plan_card
          :for={plan <- @plans}
          plan={plan}
          band={@band}
          eu?={@eu?}
          register_path={@register_path}
        />
      </div>
    </div>
    """
  end

  @doc """
  The monthly/annual segmented control. Clicking sets `data-cadence` on
  `#pricing-grid`; the active segment and the visible price blocks follow from
  Tailwind `group-data-[cadence=…]/grid` variants — entirely client-side.
  """
  def cadence_toggle(assigns) do
    ~H"""
    <div class="join" role="group" aria-label={gettext("Billing cadence")}>
      <button
        type="button"
        data-test-id="cadence-monthly"
        phx-click={JS.set_attribute({"data-cadence", "monthly"}, to: "#pricing-grid")}
        class="btn join-item btn-sm font-sans group-data-[cadence=monthly]/grid:btn-primary"
      >
        {gettext("Monthly")}
      </button>
      <button
        type="button"
        data-test-id="cadence-annual"
        phx-click={JS.set_attribute({"data-cadence", "annual"}, to: "#pricing-grid")}
        class="btn join-item btn-sm gap-2 font-sans group-data-[cadence=annual]/grid:btn-primary"
      >
        {gettext("Annual")}
        <span class="badge badge-xs badge-secondary">{gettext("2 months free")}</span>
      </button>
    </div>
    """
  end

  @doc """
  One banded subscription card. Renders both the monthly and annual price blocks;
  the active cadence is revealed by the `#pricing-grid` `data-cadence` state.
  """
  attr :plan, :map, required: true
  attr :band, :atom, default: :a
  attr :eu?, :boolean, default: false
  attr :register_path, :string, default: "/users/register"

  def plan_card(assigns) do
    price = Pricing.price_for(assigns.plan, assigns.band)

    assigns =
      assigns
      |> assign(:price, price)
      # Regional strike on the monthly card only when the band discounts AND the
      # visitor is not in the EU/EEA (Omnibus). The annual strike always shows.
      |> assign(:monthly_struck?, price.struck? and not assigns.eu?)
      |> assign(:regional?, assigns.band != :a and not assigns.eu?)

    ~H"""
    <article
      data-test-id={"plan-card-#{@plan.key}"}
      class={[
        "flex flex-col rounded-box border bg-base-100 p-6",
        @plan.popular? && "border-primary",
        !@plan.popular? && "border-base-300"
      ]}
    >
      <div class="flex items-baseline justify-between gap-2">
        <h3 class="font-display text-xl font-semibold capitalize">{@plan.name}</h3>
        <div class="text-right">
          <div class="group-data-[cadence=annual]/grid:hidden">
            <span
              :if={@monthly_struck?}
              data-test-id="monthly-list"
              class="mr-1 font-sans text-sm text-base-content/40 line-through"
            >
              {Pricing.format_cents(@price.monthly_list)}
            </span>
            <span data-test-id="monthly-price" class="font-sans text-lg font-semibold text-primary">
              {Pricing.format_cents(@price.monthly_price)}
            </span>
            <span class="font-sans text-xs text-base-content/60">{gettext("/mo")}</span>
          </div>
          <div class="hidden group-data-[cadence=annual]/grid:block">
            <span
              data-test-id="annual-list"
              class="mr-1 font-sans text-sm text-base-content/40 line-through"
            >
              {Pricing.format_cents(@price.annual_list)}
            </span>
            <span data-test-id="annual-price" class="font-sans text-lg font-semibold text-primary">
              {Pricing.format_cents(@price.annual_price)}
            </span>
            <span class="font-sans text-xs text-base-content/60">{gettext("/yr")}</span>
          </div>
        </div>
      </div>
      <p
        :if={@regional?}
        data-test-id="regional-note"
        class="mt-1 font-sans text-xs font-medium text-secondary"
      >
        {gettext("Regional pricing for your country")}
      </p>
      <ul class="mt-4 flex-1 space-y-2">
        <li
          :for={feature <- @plan.features}
          class="flex items-start gap-2 font-serif text-sm text-base-content/75"
        >
          <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
          {feature}
        </li>
      </ul>
      <.link
        navigate={@register_path}
        class="btn btn-outline btn-block mt-6 font-sans font-semibold"
      >
        {gettext("Get started")}
      </.link>
    </article>
    """
  end
end
