# Pricing Toggle + Stripe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A daisyUI paper-theme pricing UI that toggles One-time ↔ Monthly with PerfectPaper copy, backed by real Stripe (test mode) checkout + webhook fulfillment.

**Architecture:** Prices live in `Billing.Prices` config (two families). The marketing home `#pricing` and `/billing` render a shared toggled component (CSS-only radio toggle). Payments go through the existing `Billing.Provider` behaviour: a config-selected `StripeAdapter` (real) or `StubAdapter` (dev/test). Stripe-hosted Checkout (no PCI) creates sessions; a signature-verified `/webhooks/stripe` endpoint fulfills purchases idempotently via `Ecto.Multi` (`Credits.grant/3` for packs, `Subscription` upsert for plans).

**Tech Stack:** Phoenix 1.8 LiveView, Ecto/Postgres (binary_id), daisyUI v4 + Tailwind v4 (`paper` theme), `stripity_stripe`, `req`.

**Spec:** `docs/superpowers/specs/2026-05-30-pricing-toggle-design.md`

---

## File map

Phase A (no Stripe):
- Modify `lib/perfect_paper/billing/prices.ex` — add `credit_packs/0`, `subscriptions/0`, display maps; keep `list/0` delegating to `subscriptions/0`.
- Modify `lib/perfect_paper_web/components/marketing/pricing_components.ex` — `pricing_tiers/1` (two-family toggle) + `plan_card/1`.
- Modify `lib/perfect_paper_web/controllers/page_html/home.html.heex` — `#pricing` uses new component.
- Modify `lib/perfect_paper_web/live/billing_live.ex` (+ template) — render toggled pricing.
- Tests: `test/perfect_paper/billing/prices_test.exs`, `test/perfect_paper_web/components/pricing_components_test.exs`, extend billing_live test.

Phase B (Stripe):
- Modify `mix.exs` — add `{:stripity_stripe, "~> 3.2"}`.
- Modify `lib/perfect_paper/billing/provider.ex` — add `create_checkout_session/1`, `construct_webhook_event/2` callbacks.
- Modify `lib/perfect_paper/billing/stub_adapter.ex` — implement the new callbacks deterministically.
- Create `lib/perfect_paper/billing/stripe_adapter.ex` — real implementation.
- Create `priv/repo/migrations/*_add_checkout_fulfillment.exs` — extend `subscriptions.plan` enum + add `provider_session_id`; (credit-pack idempotency via credit_event metadata).
- Modify `lib/perfect_paper/billing/subscription.ex` + `lib/perfect_paper/credits/tier.ex` — new plan atoms.
- Modify `lib/perfect_paper/billing.ex` — `checkout_credit_pack/2`, `checkout_subscription/2`, `fulfill_checkout/1`.
- Modify `lib/perfect_paper/credits.ex` — `grant_idempotent/4` (skip if session already fulfilled).
- Create `lib/perfect_paper_web/controllers/checkout_controller.ex` (+ success/cancel html).
- Create `lib/perfect_paper_web/controllers/stripe_webhook_controller.ex` + `lib/perfect_paper_web/plugs/stripe_raw_body.ex`.
- Modify `lib/perfect_paper_web/router.ex` — checkout routes + webhook pipeline/route.
- Modify `config/config.exs`, `config/runtime.exs` — adapter selection + env keys/price-ids.
- Create `lib/mix/tasks/stripe.sync_products.ex`.
- Tests: provider/stub, billing context (checkout + idempotent fulfill via stub), webhook controller, prices price-id resolution.

---

## Phase A — Pricing config + UI

### Task A1: Restructure `Billing.Prices` into two families

**Files:**
- Modify: `lib/perfect_paper/billing/prices.ex`
- Test: `test/perfect_paper/billing/prices_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
defmodule PerfectPaper.Billing.PricesTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Billing.Prices

  test "credit_packs/0 returns three one-time packs, exactly one popular" do
    packs = Prices.credit_packs()
    assert length(packs) == 3
    assert Enum.count(packs, & &1.popular?) == 1
    assert Enum.all?(packs, &(&1.mode == :payment))
    assert Enum.find(packs, &(&1.key == :pack_3)).price_label == "$119.99"
  end

  test "subscriptions/0 returns three monthly plans, exactly one popular" do
    subs = Prices.subscriptions()
    assert length(subs) == 3
    assert Enum.count(subs, & &1.popular?) == 1
    assert Enum.all?(subs, &(&1.mode == :subscription))
    assert Enum.find(subs, &(&1.key == :professional)).badge == "= $33.33 / review"
  end

  test "no plan copy mentions the legacy brand name" do
    blob = (Prices.credit_packs() ++ Prices.subscriptions()) |> inspect()
    refute blob =~ "Refine"
  end
end
```

- [ ] **Step 2: Run, expect fail**

Run: `mix test test/perfect_paper/billing/prices_test.exs`
Expected: FAIL (`credit_packs/0 undefined`).

- [ ] **Step 3: Implement**

Add to `prices.ex` (keep existing `list/0` but have it delegate to `subscriptions/0` mapped to the legacy `product()` shape only if still needed; simplest: keep `list/0` returning `subscriptions/0`). New code:

```elixir
@type family :: :credit_pack | :subscription

@type plan_view :: %{
        key: atom(),
        name: String.t(),
        price_label: String.t(),
        cadence: String.t(),
        tagline: String.t(),
        badge: String.t() | nil,
        savings: String.t() | nil,
        features: [String.t()],
        popular?: boolean(),
        mode: :payment | :subscription,
        cta: String.t(),
        price_env: String.t()
      }

@spec credit_packs() :: [plan_view()]
def credit_packs do
  [
    %{key: :pack_1, name: "1 full review", price_label: "$49.99",
      cadence: "one-time use", tagline: "Pay-as-you-go flexibility",
      badge: nil, savings: nil, popular?: false, mode: :payment,
      cta: "Buy now", price_env: "STRIPE_PRICE_PACK_1",
      features: [
        "Includes all PerfectPaper suggestions",
        "Save hours of editing — PerfectPaper identifies overlooked errors in substance and style",
        "Full review in under an hour",
        "No subscription required"
      ]},
    %{key: :pack_3, name: "3 full reviews", price_label: "$119.99",
      cadence: "project package", tagline: nil, badge: nil,
      savings: "Save $30", popular?: true, mode: :payment,
      cta: "Buy now", price_env: "STRIPE_PRICE_PACK_3",
      features: [
        "Everything in the one-time-use plan, on each review",
        "Three full reviews to catch issues introduced while revising a draft, or for other papers",
        "No subscription required"
      ]},
    %{key: :pack_10, name: "10 full reviews", price_label: "$299.99",
      cadence: "professional package", tagline: nil, badge: nil,
      savings: "Save $200", popular?: false, mode: :payment,
      cta: "Buy now", price_env: "STRIPE_PRICE_PACK_10",
      features: [
        "Everything in the one-time-use plan, on each review",
        "Use credits on the same manuscript at different stages or across multiple papers",
        "Perfect for a final check after revisions",
        "No subscription required"
      ]}
  ]
end

@subscription_shared [
  "$10 off additional reviews beyond your monthly allowance",
  "Cancel anytime — no commitment",
  "Unused credits roll over each month"
]

@spec subscriptions() :: [plan_view()]
def subscriptions do
  [
    %{key: :starter, name: "Starter", price_label: "$40", cadence: "1 full review per month",
      tagline: "Perfect for occasional writers", badge: nil, savings: nil,
      popular?: false, mode: :subscription, cta: "Subscribe",
      price_env: "STRIPE_PRICE_SUB_STARTER",
      features: ["Save hours of editing — PerfectPaper identifies overlooked errors in substance and style", "Full review in under an hour" | @subscription_shared]},
    %{key: :professional, name: "Professional", price_label: "$100", cadence: "3 full reviews per month",
      tagline: "Most popular", badge: "= $33.33 / review", savings: nil,
      popular?: true, mode: :subscription, cta: "Subscribe",
      price_env: "STRIPE_PRICE_SUB_PRO",
      features: ["Three full reviews per month to catch new issues introduced while revising your draft", "Perfect for regular writers" | @subscription_shared]},
    %{key: :advanced, name: "Advanced", price_label: "$300", cadence: "10 full reviews per month",
      tagline: "For power users", badge: "= $30.00 / review", savings: nil,
      popular?: false, mode: :subscription, cta: "Subscribe",
      price_env: "STRIPE_PRICE_SUB_ADVANCED",
      features: ["Use full reviews on the same manuscript at different stages or across multiple papers", "Best for editors and frequent publishers" | @subscription_shared]}
  ]
end
```

- [ ] **Step 4: Run, expect pass.** `mix test test/perfect_paper/billing/prices_test.exs`
- [ ] **Step 5: Commit** `git add -A && git commit -m "feat(billing): two-family pricing catalogue (credit packs + subscriptions)"`

### Task A2: `pricing_tiers/1` toggled component + `plan_card/1`

**Files:**
- Modify: `lib/perfect_paper_web/components/marketing/pricing_components.ex`
- Test: `test/perfect_paper_web/components/pricing_components_test.exs`

- [ ] **Step 1: Failing test** (render both families; popular highlight; toggle present)

```elixir
defmodule PerfectPaperWeb.Marketing.PricingComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias PerfectPaperWeb.Marketing.PricingComponents

  test "renders both families, toggle, and a highlighted popular card" do
    html = render_component(&PricingComponents.pricing_tiers/1, %{})
    assert html =~ "1 full review"          # credit pack
    assert html =~ "Professional"           # subscription
    assert html =~ ~s(name="pricing_family") # CSS toggle radios
    assert html =~ "ring-primary"           # popular highlight
    assert html =~ "Buy now"
    assert html =~ "Subscribe"
    refute html =~ "indigo"                  # paper theme, not source template colour
  end
end
```

- [ ] **Step 2: Run, expect fail.** `mix test test/perfect_paper_web/components/pricing_components_test.exs`
- [ ] **Step 3: Implement.** Replace `pricing_tiers/1` body with a two-grid section gated by a CSS-only radio group `pricing_family` (`one_time` default, `monthly`), using daisyUI semantic classes. Add a private `plan_card/1`. Visibility via peer/has selectors:

```heex
<section id="pricing" class="bg-base-100 py-20 lg:py-28 group/tiers">
  <div class="max-w-6xl mx-auto px-5 sm:px-8">
    <div class="text-center max-w-2xl mx-auto mb-10">
      <h2 class="ds-h2">Choose your plan</h2>
      <p class="ds-lead mt-3 text-base-content/70">Select the plan that best fits your research needs.</p>
    </div>

    <fieldset class="mb-12 flex justify-center" aria-label="Billing type">
      <div class="join rounded-full bg-base-200 p-1">
        <label class="join-item">
          <input type="radio" name="pricing_family" value="one_time" checked class="peer/onetime sr-only" />
          <span class="btn btn-sm btn-ghost rounded-full px-4 peer-checked/onetime:btn-primary">One-time</span>
        </label>
        <label class="join-item">
          <input type="radio" name="pricing_family" value="monthly" class="peer/monthly sr-only" />
          <span class="btn btn-sm btn-ghost rounded-full px-4 peer-checked/monthly:btn-primary">Monthly</span>
        </label>
      </div>
    </fieldset>

    <div class="grid gap-6 lg:grid-cols-3 group-has-[[name=pricing_family][value=monthly]:checked]/tiers:hidden">
      <.plan_card :for={p <- PerfectPaper.Billing.Prices.credit_packs()} plan={p} />
    </div>
    <div class="hidden grid-cols-1 gap-6 lg:grid-cols-3 group-has-[[name=pricing_family][value=monthly]:checked]/tiers:grid">
      <.plan_card :for={p <- PerfectPaper.Billing.Prices.subscriptions()} plan={p} />
    </div>
  </div>
</section>
```

`plan_card/1` (paper theme; popular → `ring-2 ring-primary`; savings → `text-success`; badge → `badge-success`; CTA posts to checkout — wired in Phase B, for now `href={~p"/users/register"}`):

```heex
attr :plan, :map, required: true
def plan_card(assigns) do
  ~H"""
  <article class={["relative flex flex-col rounded-box border bg-base-100 p-6",
                   @plan.popular? && "ring-2 ring-primary border-primary", !@plan.popular? && "border-base-300"]}>
    <span :if={@plan.popular?} class="absolute -top-3 left-6 badge badge-primary">Popular</span>
    <span :if={@plan.badge} class="absolute -top-3 right-6 badge badge-success">{@plan.badge}</span>
    <h3 class="font-display text-xl">{@plan.name}</h3>
    <p class="mt-2 font-sans text-3xl font-semibold">{@plan.price_label}</p>
    <p class="text-sm text-primary">{@plan.cadence}</p>
    <p :if={@plan.savings} class="text-sm font-medium text-success">{@plan.savings}</p>
    <p :if={@plan.tagline} class="mt-2 ds-p font-semibold">{@plan.tagline}</p>
    <ul class="mt-6 space-y-3 text-sm">
      <li :for={f <- @plan.features} class="flex gap-2">
        <.icon name="hero-check" class="size-5 shrink-0 text-success" /><span>{f}</span>
      </li>
    </ul>
    <a href={~p"/users/register"} class="btn btn-primary mt-8 w-full">{@plan.cta}</a>
  </article>
  """
end
```

- [ ] **Step 4: Run, expect pass.** `mix test test/perfect_paper_web/components/pricing_components_test.exs`
- [ ] **Step 5: Commit** `git commit -am "feat(web): toggled pricing_tiers (one-time/monthly) on paper theme"`

### Task A3: Wire marketing home `#pricing`

**Files:** Modify `lib/perfect_paper_web/controllers/page_html/home.html.heex` (lines ~12–40, the current `#pricing` section).

- [ ] **Step 1:** Replace the hand-rolled `<section id="pricing">…Prices.list()…</section>` with `<PerfectPaperWeb.Marketing.PricingComponents.pricing_tiers />`.
- [ ] **Step 2:** Run `mix compile` — expect clean.
- [ ] **Step 3:** Manual: visit `/#pricing`, toggle works, three cards per family.
- [ ] **Step 4: Commit** `git commit -am "feat(web): home pricing uses toggled pricing_tiers"`

### Task A4: Wire `/billing`

**Files:** Modify `lib/perfect_paper_web/live/billing_live.ex` (+ its template) to render `PricingComponents.pricing_tiers` in place of the bespoke subscription grid; keep the credit-balance panel.

- [ ] **Step 1:** Add failing assertion to the existing billing_live test: page renders "1 full review" and "Subscribe".
- [ ] **Step 2:** Run, expect fail.
- [ ] **Step 3:** Render `<PricingComponents.pricing_tiers />` inside the billing template.
- [ ] **Step 4:** Run billing_live test, expect pass.
- [ ] **Step 5: Commit** `git commit -am "feat(web): /billing renders toggled pricing"`

**Phase A ships here** — pricing UI is live on both surfaces, no keys required.

---

## Phase B — Stripe (test mode)

### Task B1: Add dependency + base config

**Files:** Modify `mix.exs`, `config/config.exs`.

- [ ] **Step 1:** Add `{:stripity_stripe, "~> 3.2"}` to deps. Run `mix deps.get`.
- [ ] **Step 2:** In `config/config.exs` add:

```elixir
config :perfect_paper, :billing_provider, PerfectPaper.Billing.StubAdapter
config :stripity_stripe, api_key: {:system, "STRIPE_SECRET_KEY"}
```

- [ ] **Step 3:** `mix compile` clean. **Commit** `git commit -am "chore(deps): add stripity_stripe"`

### Task B2: Extend Provider behaviour + StubAdapter

**Files:** Modify `provider.ex`, `stub_adapter.ex`. Test: `test/perfect_paper/billing/stub_adapter_test.exs`.

- [ ] **Step 1: Failing test**

```elixir
test "create_checkout_session returns a checkout_url and session_id" do
  assert {:ok, %{checkout_url: "https://" <> _, session_id: "cs_stub_" <> _}} =
           PerfectPaper.Billing.StubAdapter.create_checkout_session(%{
             mode: :payment, price_id: "price_x", quantity: 1,
             customer_email: "a@b.co", success_url: "u", cancel_url: "u",
             metadata: %{kind: "credit_pack", pack: "pack_1"}
           })
end

test "construct_webhook_event echoes a normalized event for the stub signature" do
  assert {:ok, %{type: "checkout.session.completed", session_id: "cs_stub_1", metadata: %{}}} =
           PerfectPaper.Billing.StubAdapter.construct_webhook_event(
             ~s({"session_id":"cs_stub_1"}), "stub")
end
```

- [ ] **Step 2:** Run, expect fail.
- [ ] **Step 3:** Add callbacks to `provider.ex`:

```elixir
@callback create_checkout_session(attrs :: map()) ::
            {:ok, %{required(:checkout_url) => String.t(), required(:session_id) => String.t()}} | {:error, term()}
@callback construct_webhook_event(raw_body :: binary(), signature :: String.t()) ::
            {:ok, %{required(:type) => String.t(), required(:session_id) => String.t(), optional(:customer_id) => String.t(), optional(:metadata) => map()}} | {:error, term()}
```

Implement in `stub_adapter.ex`: return `%{checkout_url: "https://stub.checkout/" <> rand(), session_id: "cs_stub_" <> rand()}`; `construct_webhook_event/2` decodes the JSON body and returns `%{type: "checkout.session.completed", session_id: body["session_id"], metadata: %{}}`.

- [ ] **Step 4:** Run, expect pass. **Commit** `git commit -am "feat(billing): checkout + webhook callbacks on Provider seam (+stub)"`

### Task B3: `StripeAdapter`

**Files:** Create `lib/perfect_paper/billing/stripe_adapter.ex`.

- [ ] **Step 1:** Implement `@behaviour Provider`. `create_checkout_session/1` calls `Stripe.Checkout.Session.create(%{mode:, line_items: [%{price: price_id, quantity:}], success_url:, cancel_url:, customer_email:, metadata:})`, returns `{:ok, %{checkout_url: session.url, session_id: session.id}}`. `construct_webhook_event/2` calls `Stripe.Webhook.construct_event(raw_body, signature, secret)` where `secret = Application.fetch_env!(:perfect_paper, :stripe_webhook_secret)`; normalize the `%Stripe.Event{}` into the atom-map shape (extract `event.type`, `event.data.object.id`, `.customer`, `.metadata`). On signature failure return `{:error, :invalid_signature}`. Keep the existing `create_customer/create_subscription/cancel_subscription` callbacks implemented (delegate to Stripe customer/subscription APIs) or raise `:not_implemented` if unused this pass — implement `create_customer` (used by subscription fulfillment).
- [ ] **Step 2:** `mix compile` clean (no network in compile). **Commit** `git commit -am "feat(billing): StripeAdapter (hosted checkout + webhook verify)"`

### Task B4: New plan atoms + price-id resolution

**Files:** Create migration; modify `subscription.ex`, `credits/tier.ex`, `prices.ex`.

- [ ] **Step 1:** Migration: alter `subscriptions.plan` enum is a string (`Ecto.Enum`), so no DB enum change needed — just widen the schema's `values:` to `[:free, :standard, :pro, :starter, :professional, :advanced]`. Add column `add :provider_session_id, :string` to `subscriptions` for idempotency; `create unique_index(:subscriptions, [:provider_session_id])`.
- [ ] **Step 2:** Update `Subscription` schema `values:` + cast `:provider_session_id`. Update `Credits.Tier` `@tiers` with `starter: %{monthly_credits: 10, max_doc_words: 20_000}`, `professional: %{monthly_credits: 30, …}`, `advanced: %{monthly_credits: 100, max_doc_words: :unlimited}` (1 review = 10 credits).
- [ ] **Step 3:** Add to `prices.ex`: `price_id(plan_view)` → `System.get_env(plan_view.price_env)`. Test: with the env var set, `price_id` returns it.
- [ ] **Step 4:** `mix ecto.migrate`; run tier/prices tests. **Commit** `git commit -am "feat(billing): subscription plan atoms + price-id resolution + idempotency column"`

### Task B5: Billing context — checkout + idempotent fulfillment

**Files:** Modify `lib/perfect_paper/billing.ex`, `lib/perfect_paper/credits.ex`. Test: `test/perfect_paper/billing_test.exs` (use a test adapter or StubAdapter).

- [ ] **Step 1: Failing tests** (against StubAdapter):
  - `checkout_credit_pack(user, :pack_3)` returns `{:ok, %{checkout_url: _}}` and built session attrs have `mode: :payment`, `metadata: %{kind: "credit_pack", pack: "pack_3", user_id: user.id}`.
  - `fulfill_checkout(%{type: "checkout.session.completed", session_id: "cs_1", metadata: %{"kind" => "credit_pack", "pack" => "pack_1", "user_id" => uid}})` grants 10 credits and is a no-op on replay (balance unchanged).
- [ ] **Step 2:** Run, expect fail.
- [ ] **Step 3:** Implement:

```elixir
@credits_per_review 10

def checkout_credit_pack(user, pack_key) do
  pack = Enum.find(Prices.credit_packs(), &(&1.key == pack_key)) || raise ArgumentError
  provider().create_checkout_session(%{
    mode: :payment, price_id: Prices.price_id(pack), quantity: 1,
    customer_email: user.email,
    success_url: url(~p"/checkout/success"), cancel_url: url(~p"/checkout/cancel"),
    metadata: %{kind: "credit_pack", pack: Atom.to_string(pack_key), user_id: user.id}
  })
end
# checkout_subscription/2 analogous with mode: :subscription, metadata kind "subscription".

def fulfill_checkout(%{metadata: %{"kind" => "credit_pack"} = m, session_id: sid}) do
  pack = Enum.find(Prices.credit_packs(), &(Atom.to_string(&1.key) == m["pack"]))
  amount = review_credits(pack) # packs: pack_1->10, pack_3->30, pack_10->100
  Credits.grant_idempotent(m["user_id"], amount, "stripe_pack:#{m["pack"]}", sid)
end
def fulfill_checkout(%{metadata: %{"kind" => "subscription"} = m, session_id: sid, customer_id: cid}) do
  # upsert Subscription with provider_session_id sid (skip if exists), plan = m["plan"], status :active
end

defp provider, do: Application.fetch_env!(:perfect_paper, :billing_provider)
```

`Credits.grant_idempotent/4`: if a `credit_events` row already has `metadata["stripe_session_id"] == sid`, return `{:ok, :already_fulfilled}`; else `grant/3` writing `stripe_session_id` into metadata inside one transaction.

- [ ] **Step 4:** Run, expect pass. **Commit** `git commit -am "feat(billing): checkout_* + idempotent fulfill_checkout"`

### Task B6: CheckoutController + landing pages + routes

**Files:** Create `checkout_controller.ex`, `checkout_html.ex` + success/cancel templates; modify `router.ex`.

- [ ] **Step 1:** Controller actions `credits/2` (`POST /checkout/credits/:pack`) and `subscription/2` (`POST /checkout/subscription/:plan`): call `Billing.checkout_*`, `redirect(external: checkout_url)`. `success/2`, `cancel/2` render simple paper-theme pages.
- [ ] **Step 2:** Routes inside the authenticated browser scope. Run controller test asserting a 302 to the stub checkout URL.
- [ ] **Step 3:** Expect pass. **Commit** `git commit -am "feat(web): checkout controller + success/cancel pages"`

### Task B7: Stripe webhook (raw body + signature)

**Files:** Create `plugs/stripe_raw_body.ex`, `stripe_webhook_controller.ex`; modify `router.ex` + `endpoint.ex`.

- [ ] **Step 1:** Endpoint: in `Plug.Parsers`, set `body_reader: {PerfectPaperWeb.Plugs.StripeRawBody, :read_body, []}` OR add a dedicated parserless pipeline for the webhook path that caches `raw_body` in conn assigns. Simplest: a `:stripe_webhook` pipeline with `plug :fetch_raw_body` (reads and stores full body) and no CSRF.
- [ ] **Step 2: Failing test:** POST bad signature → 400; POST good stub event → 200 and fulfillment ran; replay → 200 and idempotent.
- [ ] **Step 3:** Controller: read raw body + `stripe-signature` header → `provider().construct_webhook_event/2` → on `{:ok, event}` `Billing.fulfill_checkout(event)` → `send_resp(conn, 200, "")`; on `{:error, _}` → `send_resp(conn, 400, "")`.
- [ ] **Step 4:** Route `post "/webhooks/stripe"` under the webhook pipeline. Run test, expect pass. **Commit** `git commit -am "feat(web): signed Stripe webhook + idempotent fulfillment"`

### Task B8: Wire pricing CTAs to checkout

**Files:** Modify `pricing_components.ex` `plan_card/1`.

- [ ] **Step 1:** Replace the CTA `<a href={~p"/users/register"}>` with a form that POSTs to the right checkout route by family/key, e.g. `<.form for={%{}} action={checkout_path(@plan)} method="post"><button class="btn btn-primary w-full">{@plan.cta}</button></.form>` where `checkout_path` picks `~p"/checkout/credits/#{key}"` or `~p"/checkout/subscription/#{key}"`. For signed-out users on marketing, route to register first (carry intent param). Update component test for the action attr.
- [ ] **Step 2:** Run component test. **Commit** `git commit -am "feat(web): pricing CTAs post to Stripe checkout"`

### Task B9: `mix stripe.sync_products`

**Files:** Create `lib/mix/tasks/stripe.sync_products.ex`.

- [ ] **Step 1:** Task starts the app, iterates `Prices.credit_packs() ++ Prices.subscriptions()`, creates a Stripe Product + Price (one-time vs recurring/month per `mode`) using `stripity_stripe`, prints `export <price_env>=<price_id>` lines for the operator to paste into env. Idempotent-ish: look up by product name first.
- [ ] **Step 2:** `mix compile` clean (don't run without a key). **Commit** `git commit -am "feat(billing): mix stripe.sync_products task"`

### Task B10: runtime.exs env wiring + adapter selection

**Files:** Modify `config/runtime.exs`.

- [ ] **Step 1:** If `STRIPE_SECRET_KEY` present: `config :perfect_paper, :billing_provider, PerfectPaper.Billing.StripeAdapter` and `config :perfect_paper, :stripe_webhook_secret, System.get_env("STRIPE_WEBHOOK_SECRET")`. Price-ids resolve via `System.get_env` in `Prices.price_id/1` (already). When absent, stay on StubAdapter (default from config.exs).
- [ ] **Step 2:** `mix compile` clean. **Commit** `git commit -am "feat(billing): select StripeAdapter when keys present (runtime.exs)"`

### Task B11: End-to-end manual verification (with your keys)

- [ ] Operator sets `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`; runs `mix stripe.sync_products`, pastes the printed `STRIPE_PRICE_*` into env.
- [ ] `stripe listen --forward-to localhost:4000/webhooks/stripe` in one terminal.
- [ ] `mix phx.server`; buy a pack with test card `4242 4242 4242 4242`; confirm webhook 200 and credit balance increased; subscribe and confirm Subscription row active. Idempotency: re-send the event via `stripe trigger`/replay → balance unchanged.

---

## Self-review notes
- Spec coverage: pricing config (A1), component+toggle (A2), both surfaces (A3/A4), provider seam (B2/B3), plan atoms + idempotency (B4), context checkout/fulfill (B5), checkout web (B6), signed webhook (B7), CTAs (B8), product sync (B9), adapter selection (B10), e2e (B11) — all spec sections mapped.
- Idempotency: credit packs via `credit_events.metadata.stripe_session_id`; subscriptions via `subscriptions.provider_session_id` unique index.
- No network in dev/test: StubAdapter is the configured provider unless `STRIPE_SECRET_KEY` is set.
- Brand: copy uses "PerfectPaper"; A1 test asserts no "Refine" leak.
