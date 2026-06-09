defmodule PerfectPaperWeb.BillingLive do
  @moduledoc """
  Billing LiveView — subscription plans and credit balance for signed-in users.

  Renders two tabs:

  - **Subscription** — a responsive grid of pricing cards from the product
    catalogue (`Billing.list_products/0`). The user's current plan is
    highlighted; every other plan gets a "Choose plan" action wired to the
    `upgrade` event.
  - **Credits** — the user's current credit balance (derived from the append-
    only ledger via `Credits.balance/1`) and a presentational set of credit-pack
    options (purchasing is a future capability).

  All mutations route through the `PerfectPaper.Billing` context only.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Billing, Credits}
  alias PerfectPaper.Billing.{Prices, Pricing}

  # Allowlisted phx-value params — guarded in the function head so a crafted
  # WebSocket message with an unknown atom string can't reach String.to_existing_atom
  # and crash the LiveView process.
  @valid_tabs ~w(subscription credits)
  @valid_cadences ~w(monthly annual)
  @valid_plans ~w(starter professional advanced)
  @valid_packs ~w(pack_3 pack_6 pack_12 credit_single)

  # ── Mount ──────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user

    # Read the regional band + country from the session (written by
    # FetchPricingCountry). The *connected* mount has no conn assigns, so the
    # session is the single deterministic source; default to Band A / no country.
    band = session["pricing_band"] || :a
    country = session["pricing_country"]

    {:ok,
     assign(socket,
       page_title: gettext("Subscription & credits"),
       tab: :subscription,
       cadence: :monthly,
       user: user,
       products: Billing.list_products(),
       credit_packs: Prices.credit_packs(),
       pricing_band: band,
       pricing_country: country,
       pricing_eu?: Pricing.eu_country?(country),
       portal_supported?: Billing.portal_supported?(),
       checkout_mode: false,
       checkout_secret: nil,
       checkout_nonce: nil,
       subscription: Billing.get_subscription_for_user(user.id),
       balance: Credits.balance(user.id)
     )}
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_tab", %{"tab" => t}, socket) when t in @valid_tabs do
    {:noreply, assign(socket, tab: String.to_existing_atom(t))}
  end

  def handle_event("select_tab", _params, socket), do: {:noreply, socket}

  def handle_event("set_cadence", %{"cadence" => cadence}, socket)
      when cadence in @valid_cadences do
    {:noreply, assign(socket, cadence: String.to_existing_atom(cadence))}
  end

  def handle_event("set_cadence", _params, socket), do: {:noreply, socket}

  def handle_event("upgrade", %{"plan" => plan}, socket) when plan in @valid_plans do
    user = socket.assigns.user
    plan_atom = String.to_existing_atom(plan)
    cadence = socket.assigns.cadence

    opts = [
      ip_country: socket.assigns.pricing_country,
      success_url: url(~p"/billing/success"),
      cancel_url: url(~p"/billing")
    ]

    # Dispatches on the provider: Stripe → redirect to hosted checkout (the sub is
    # confirmed asynchronously via webhook); stub → synchronous subscribe.
    case Billing.start_checkout(user, plan_atom, cadence, opts) do
      {:ok, {:checkout, checkout_url}} ->
        {:noreply, redirect(socket, external: checkout_url)}

      {:ok, {:embedded, client_secret}} ->
        # Mount Stripe's embedded checkout in-app. A fresh nonce keys the wrapper's
        # DOM id so a new secret forces the JS hook to remount.
        {:noreply,
         assign(socket,
           checkout_mode: true,
           checkout_secret: client_secret,
           checkout_nonce: System.unique_integer([:positive])
         )}

      {:ok, {:subscribed, subscription}} ->
        {:noreply,
         socket
         |> assign(subscription: subscription, balance: Credits.balance(user.id))
         |> put_flash(
           :info,
           gettext("Your plan has been updated to %{plan}.", plan: String.capitalize(plan))
         )}

      {:error, :already_subscribed} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("You're already on the %{plan} plan.", plan: String.capitalize(plan))
         )}

      {:error, :change_plan_in_portal} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("You already have a plan. Use \"Manage billing\" to switch plans.")
         )}

      {:error, :recover_in_portal} ->
        {:noreply,
         put_flash(
           socket,
           :warning,
           gettext(
             "Your subscription needs attention. Use \"Manage billing\" to update your payment method."
           )
         )}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("We were unable to change your plan. Please try again.")
         )}
    end
  end

  def handle_event("upgrade", _params, socket), do: {:noreply, socket}

  def handle_event("buy_pack", %{"pack" => pack}, socket) when pack in @valid_packs do
    user = socket.assigns.user
    pack_atom = String.to_existing_atom(pack)
    reviews = pack_reviews(pack_atom)

    opts = [
      ip_country: socket.assigns.pricing_country,
      success_url: url(~p"/billing/success"),
      cancel_url: url(~p"/billing")
    ]

    # Dispatches on the provider: Stripe → redirect to a one-time checkout (the
    # credits are granted by the checkout.session.completed webhook); stub → grants
    # synchronously.
    case Billing.start_pack_checkout(user, pack_atom, reviews, opts) do
      {:ok, {:checkout, checkout_url}} ->
        {:noreply, redirect(socket, external: checkout_url)}

      {:ok, {:granted, count}} ->
        {:noreply,
         socket
         |> assign(balance: Credits.balance(user.id))
         |> put_flash(
           :info,
           gettext("Added %{count} review credits to your balance.", count: count)
         )}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("We couldn't complete that purchase. Please try again.")
         )}
    end
  end

  def handle_event("buy_pack", _params, socket), do: {:noreply, socket}

  def handle_event("exit_checkout", _params, socket) do
    {:noreply, assign(socket, checkout_mode: false, checkout_secret: nil, checkout_nonce: nil)}
  end

  # Pushed by the StripeEmbeddedCheckout hook when it can't render (Stripe.js load
  # failure, missing key, init throw) — leave checkout and surface the failure.
  def handle_event("checkout_client_error", _params, socket) do
    {:noreply,
     socket
     |> assign(checkout_mode: false, checkout_secret: nil, checkout_nonce: nil)
     |> put_flash(:error, gettext("We couldn't open the secure checkout. Please try again."))}
  end

  def handle_event("manage_billing", _params, socket) do
    case Billing.billing_portal_url(socket.assigns.user, url(~p"/billing")) do
      {:ok, portal_url} ->
        {:noreply, redirect(socket, external: portal_url)}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("We couldn't open the billing portal. Please try again.")
         )}
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.app
      active={:billing}
      title={gettext("Subscription & credits")}
      flash={@flash}
      current_scope={@current_scope}
      credit_alert={@credit_alert}
      low_credit_dismissed?={@low_credit_dismissed?}
      current_workspace={@current_workspace}
      workspaces={@workspaces}
      max_width="max-w-4xl"
    >
      <%!-- Embedded Stripe checkout (in-app). The wrapper is phx-update="ignore"
           and keyed by the nonce so a new secret remounts the JS hook. --%>
      <div :if={@checkout_mode} class="mx-auto max-w-xl py-4">
        <button
          type="button"
          phx-click="exit_checkout"
          class="btn btn-ghost btn-sm mb-4 gap-1 font-sans"
        >
          <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to plans")}
        </button>
        <div
          id={"embedded-checkout-#{@checkout_nonce}"}
          phx-hook="StripeEmbeddedCheckout"
          phx-update="ignore"
          data-client-secret={@checkout_secret}
          data-publishable-key={Billing.stripe_publishable_key()}
        >
        </div>
      </div>

      <%!-- Tab bar --%>
      <div :if={!@checkout_mode} role="tablist" class="tabs tabs-bordered mb-8">
        <button
          role="tab"
          class={["tab font-sans text-sm font-medium", @tab == :subscription && "tab-active"]}
          phx-click="select_tab"
          phx-value-tab="subscription"
        >
          {gettext("Subscription")}
        </button>
        <button
          role="tab"
          class={["tab font-sans text-sm font-medium", @tab == :credits && "tab-active"]}
          phx-click="select_tab"
          phx-value-tab="credits"
        >
          {gettext("Credits")}
        </button>
      </div>

      <%!-- Tab panels --%>
      <div :if={!@checkout_mode and @tab == :subscription}>
        <.subscription_tab
          products={@products}
          subscription={@subscription}
          band={@pricing_band}
          pricing_eu?={@pricing_eu?}
          cadence={@cadence}
          portal_supported?={@portal_supported?}
        />
      </div>
      <div :if={!@checkout_mode and @tab == :credits}>
        <.credits_tab balance={@balance} packs={@credit_packs} band={@pricing_band} />
      </div>
    </.app>
    """
  end

  # ── Private components ─────────────────────────────────────────────────────

  attr :products, :list, required: true
  attr :subscription, :any, default: nil
  attr :band, :atom, default: :a
  attr :pricing_eu?, :boolean, default: false
  attr :cadence, :atom, default: :monthly
  attr :portal_supported?, :boolean, default: false

  defp subscription_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-8 text-center">
        <h1 class="ds-h2 mb-2">{gettext("Choose your plan")}</h1>
        <p class="ds-lead text-base-content/65">
          {gettext("Select the plan that best supports your research needs.")}
        </p>
      </div>

      <%!-- Free-previews banner when there's no active subscription --%>
      <div
        :if={is_nil(@subscription) or @subscription.status == :canceled}
        class="mb-6 flex items-center gap-3 rounded-lg border border-base-300 bg-base-200/60 px-4 py-3"
      >
        <span class="badge badge-secondary badge-sm font-sans">{gettext("Free preview")}</span>
        <span class="font-sans text-sm text-base-content/75">
          {gettext(
            "You're on free previews — a preview of the full review, on us. Subscribe for full reviews every month."
          )}
        </span>
      </div>

      <%!-- Status banner when a plan is active --%>
      <div
        :if={@subscription && @subscription.status != :canceled}
        class="mb-6 flex items-center gap-3 rounded-lg border border-base-300 bg-base-200/60 px-4 py-3"
      >
        <span class={[
          "badge badge-sm font-sans",
          @subscription.status == :active && "badge-success",
          @subscription.status == :past_due && "badge-warning"
        ]}>
          {Billing.Subscription.status_label(@subscription)}
        </span>
        <span class="font-sans text-sm text-base-content/75">
          {gettext("You are on the %{plan} plan.",
            plan: Billing.Subscription.plan_label(@subscription)
          )}
          <%= if @subscription.current_period_end do %>
            {gettext("Current period ends %{date}.",
              date: Calendar.strftime(@subscription.current_period_end, "%B %-d, %Y")
            )}
          <% end %>
        </span>
        <%!-- Self-service portal: cancel, update card, or switch plans on Stripe.
              Shown only when the provider supports it and a real customer exists. --%>
        <button
          :if={@portal_supported? && @subscription.provider_customer_id}
          type="button"
          phx-click="manage_billing"
          phx-disable-with={gettext("Opening…")}
          class="btn btn-outline btn-sm ml-auto shrink-0 font-sans"
        >
          {gettext("Manage billing")}
        </button>
      </div>

      <%!-- Monthly / annual cadence toggle --%>
      <div class="mb-6 flex justify-center">
        <div class="join" role="group" aria-label={gettext("Billing cadence")}>
          <button
            class={["btn join-item btn-sm font-sans", @cadence == :monthly && "btn-primary"]}
            phx-click="set_cadence"
            phx-value-cadence="monthly"
          >
            {gettext("Monthly")}
          </button>
          <button
            class={["btn join-item btn-sm gap-2 font-sans", @cadence == :annual && "btn-primary"]}
            phx-click="set_cadence"
            phx-value-cadence="annual"
          >
            {gettext("Annual")}
            <span class="badge badge-xs badge-secondary">{gettext("2 months free")}</span>
          </button>
        </div>
      </div>

      <%!-- Pricing grid --%>
      <div class="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
        <.plan_card
          :for={product <- @products}
          product={product}
          band={@band}
          pricing_eu?={@pricing_eu?}
          cadence={@cadence}
          current_plan={current_plan(@subscription)}
        />
      </div>

      <p class="mt-8 text-center font-sans text-sm text-base-content/50">
        {gettext("All plans include a 7-day trial period. Cancel anytime — no questions asked.")}
      </p>
    </div>
    """
  end

  attr :product, :map, required: true
  attr :band, :atom, default: :a
  attr :pricing_eu?, :boolean, default: false
  attr :cadence, :atom, default: :monthly
  attr :current_plan, :atom, default: nil

  defp plan_card(assigns) do
    price = Pricing.price_for(assigns.product, assigns.band)
    annual? = assigns.cadence == :annual

    # EU Omnibus Directive: a struck reference price must be a genuine prior
    # selling price. The monthly regional strike is a synthetic comparison (we
    # never actually charged Band-A on this visitor), so suppress it for EU/EEA.
    # Annual is a real saving (2 months free) and always strikes.
    monthly_struck? = price.struck? && !assigns.pricing_eu?

    assigns =
      assign(assigns,
        key: plan_key(assigns.product),
        is_current: plan_key(assigns.product) == assigns.current_plan,
        is_popular: plan_popular?(assigns.product),
        price: price,
        amount: if(annual?, do: price.annual_price, else: price.monthly_price),
        list: if(annual?, do: price.annual_list, else: price.monthly_list),
        struck?: if(annual?, do: true, else: monthly_struck?),
        unit: if(annual?, do: gettext("/yr"), else: gettext("/mo"))
      )

    ~H"""
    <div class={[
      "card border bg-base-100 flex flex-col",
      @is_current && "border-primary ring-1 ring-primary/30",
      @is_popular && !@is_current && "border-secondary",
      !@is_current && !@is_popular && "border-base-300"
    ]}>
      <%!-- Popular badge --%>
      <div class="relative">
        <div :if={@is_popular} class="absolute -top-3 left-1/2 -translate-x-1/2">
          <span class="badge badge-secondary badge-sm font-sans font-semibold uppercase tracking-wider">
            {gettext("Most popular")}
          </span>
        </div>
      </div>

      <div class="card-body flex flex-col gap-4 p-6">
        <%!-- Plan name + current badge --%>
        <div class="flex items-start justify-between gap-2">
          <h2 class="font-display text-lg font-semibold">
            {plan_name(@product)}
          </h2>
          <span
            :if={@is_current}
            class="badge badge-primary badge-sm shrink-0 font-sans font-medium"
          >
            {gettext("Current plan")}
          </span>
        </div>

        <%!-- Price (cadence + band aware: struck list when discounted) --%>
        <div>
          <span :if={@struck?} class="mr-1 font-sans text-base text-base-content/40 line-through">
            {Pricing.format_cents(@list)}
          </span>
          <span class="font-display text-4xl font-bold text-base-content">
            {Pricing.format_cents(@amount)}
          </span>
          <span class="ml-1 font-sans text-sm text-base-content/55">{@unit}</span>
          <p :if={@price.struck?} class="mt-1 font-sans text-xs font-medium text-secondary">
            {gettext("Regional pricing for your country")}
          </p>
          <p :if={plan_cadence(@product)} class="mt-1 font-sans text-sm text-base-content/55">
            {plan_cadence(@product)}
          </p>
        </div>

        <%!-- Feature list --%>
        <ul class="flex-1 space-y-2">
          <li :for={feature <- plan_features(@product)} class="flex items-start gap-2">
            <svg
              class="mt-0.5 size-4 shrink-0 text-secondary"
              viewBox="0 0 20 20"
              fill="currentColor"
              aria-hidden="true"
            >
              <path
                fill-rule="evenodd"
                d="M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z"
                clip-rule="evenodd"
              />
            </svg>
            <span class="font-sans text-sm text-base-content/80">{feature}</span>
          </li>
        </ul>

        <%!-- CTA --%>
        <div class="mt-2">
          <button
            :if={!@is_current}
            class={[
              "btn btn-block font-sans font-semibold",
              (@is_popular && "btn-secondary") || "btn-primary"
            ]}
            phx-click="upgrade"
            phx-value-plan={@key}
          >
            {gettext("Choose %{plan}", plan: plan_name(@product))}
          </button>
          <button :if={@is_current} class="btn btn-block btn-outline btn-disabled font-sans" disabled>
            {gettext("Current plan")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :balance, :integer, required: true
  attr :packs, :list, required: true
  attr :band, :atom, default: :a

  defp credits_tab(assigns) do
    ~H"""
    <div>
      <div class="mb-8 text-center">
        <h1 class="ds-h2 mb-2">{gettext("Your credits")}</h1>
        <p class="ds-lead text-base-content/65">
          {gettext(
            "Credits are used for each proofreading session. Unused credits carry over each month."
          )}
        </p>
      </div>

      <%!-- Balance card --%>
      <div class="card border border-base-300 bg-base-100 mb-8">
        <div class="card-body flex flex-row items-center justify-between px-6 py-5">
          <div>
            <p class="ds-eyebrow mb-1 text-base-content/50">{gettext("Current balance")}</p>
            <span class="font-display text-5xl font-bold text-primary">{@balance}</span>
            <span class="ml-2 font-sans text-lg text-base-content/55">{gettext("credits")}</span>
          </div>
          <div class="text-right">
            <p class="font-sans text-sm text-base-content/55">
              {gettext("Each full review costs")}
            </p>
            <p class="font-display text-2xl font-semibold text-base-content">
              1
              <span class="font-sans text-base font-normal text-base-content/55">
                {gettext("credit")}
              </span>
            </p>
          </div>
        </div>
      </div>

      <%!-- Credit packs --%>
      <div class="mb-6">
        <h2 class="ds-h3 mb-1">{gettext("Buy additional credits")}</h2>
        <p class="font-sans text-sm text-base-content/55">
          {gettext("One-time review bundles — no subscription. Unused credits never expire.")}
        </p>
      </div>

      <div class="grid gap-5 sm:grid-cols-3">
        <.credit_pack_card :for={pack <- @packs} pack={pack} band={@band} />
      </div>
    </div>
    """
  end

  attr :pack, :map, required: true
  attr :band, :atom, default: :a

  defp credit_pack_card(assigns) do
    price = Pricing.pack_price_for(assigns.pack, assigns.band)

    assigns =
      assign(assigns,
        price: price,
        featured: plan_popular?(assigns.pack),
        reviews: pack_reviews(assigns.pack.key)
      )

    ~H"""
    <div class={[
      "card border bg-base-100",
      @featured && "border-accent ring-1 ring-accent/25",
      !@featured && "border-base-300"
    ]}>
      <div class="card-body p-5">
        <div class="flex items-start justify-between gap-2">
          <p class="font-display text-base font-semibold">{@pack.name}</p>
          <span
            :if={@pack.savings}
            class="badge badge-accent badge-sm font-sans text-[10px] font-semibold"
          >
            {@pack.savings}
          </span>
        </div>

        <div class="my-1">
          <span
            :if={@price.struck?}
            class="mr-1 font-sans text-base text-base-content/40 line-through"
          >
            {Pricing.format_cents(@price.list)}
          </span>
          <span class="font-display text-3xl font-bold text-base-content">
            {Pricing.format_cents(@price.price)}
          </span>
        </div>

        <p class="mb-3 font-sans text-sm text-base-content/60">
          {gettext("%{count} review credits — one-time", count: @reviews)}
        </p>

        <button
          class="btn btn-block btn-outline btn-sm font-sans"
          phx-click="buy_pack"
          phx-value-pack={@pack.key}
          phx-disable-with={gettext("Adding…")}
        >
          {gettext("Buy now")}
        </button>
      </div>
    </div>
    """
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec current_plan(Billing.Subscription.t() | nil) :: atom() | nil
  defp current_plan(nil), do: nil
  defp current_plan(%Billing.Subscription{plan: plan}), do: plan

  # Plan-card field access — works whether Prices yields the rich plan_map
  # (`:key` / `:name` / `:price_label` / `:cadence` / `:popular?`) or a legacy
  # product map (`:plan` / `:price_cents`).
  defp plan_key(%{key: key}), do: key
  defp plan_key(%{plan: plan}), do: plan
  defp plan_key(_), do: nil

  defp plan_name(%{name: name}) when is_binary(name), do: name
  defp plan_name(%{plan: plan}), do: plan |> to_string() |> String.capitalize()
  defp plan_name(_), do: "Plan"

  defp plan_cadence(plan), do: Map.get(plan, :cadence)
  defp plan_features(plan), do: Map.get(plan, :features, [])
  defp plan_popular?(plan), do: Map.get(plan, :popular?, false)

  # Review credits granted by each one-time bundle (1 credit = 1 full review).
  defp pack_reviews(:pack_3), do: 3
  defp pack_reviews(:pack_6), do: 6
  defp pack_reviews(:pack_12), do: 12
  defp pack_reviews(:credit_single), do: 1
end
