# Pricing toggle + Stripe — design

Date: 2026-05-30
Status: approved (build fresh on `main`; prices restructured into config; real
Stripe payments in **test mode**)

## Goal

A toggled pricing UI in two surfaces, in the daisyUI **paper** theme (mulberry
primary / teal / gold-fills on cream — not the indigo of the source Tailwind
Plus templates). Copy and pricing follow the Refine.ink reference screenshots,
rebranded to **PerfectPaper** (CLAUDE.md: always "PerfectPaper", one word, no
emoji, sentence case). The toggle flips **One-time ↔ Monthly** (replacing the
source templates' monthly/annual).

## Product families (source of truth: `Billing.Prices` config)

Two pure-config catalogues, each a list of display maps with keys: `key`,
`name`, `price_label`, `cadence`, `tagline`, `badge` (optional), `savings`
(optional), `features` (list), `popular?` (bool), `cta`.

### One-time — "Buy credits"
- **1 Full Review** — $49.99 — "one-time use" — tagline "Pay-as-you-go flexibility"
  - Includes all PerfectPaper suggestions
  - Save hours of editing — PerfectPaper identifies overlooked errors in substance and style
  - Full review in under an hour
  - No subscription required
- **3 Full Reviews** — $119.99 — "project package" — savings "Save $30" — **popular**
  - Everything in the one-time-use plan on each review
  - Three full reviews to catch issues introduced while revising a draft, or for other papers
  - No subscription required
- **10 Full Reviews** — $299.99 — "professional package" — savings "Save $200"
  - Everything in the one-time-use plan on each review
  - Use credits on the same manuscript at different stages or across multiple papers
  - Perfect for a final check after revisions
  - No subscription required

CTA: "Buy now". Footer: institutional subscription link → `/contact`;
"see real examples" → `/examples`.

### Monthly — "Subscription plans"
- **Starter** — $40/mo — "1 full review per month" — tagline "Perfect for occasional writers"
- **Professional** — $100/mo — "3 full reviews per month" — badge "= $33.33 / review" — **popular**
- **Advanced** — $300/mo — "10 full reviews per month" — badge "= $30.00 / review"

Shared subscription features (per card, lightly varied per screenshots):
$10 off additional reviews beyond the monthly allowance; cancel anytime — no
commitment; unused credits roll over each month. CTA: "Subscribe".

## Components & surfaces

- `lib/perfect_paper/billing/prices.ex` — restructured: `credit_packs/0` and
  `subscriptions/0` return the catalogues above. Pure config; single source of
  truth for both surfaces.
- `lib/perfect_paper_web/components/marketing/pricing_components.ex` —
  `pricing_tiers/1` reworked into a two-family toggled section with a shared
  `plan_card/1`. Popular card highlighted with `ring-primary`; savings and
  per-review notes use `text-success` / `badge-success`. daisyUI semantic
  classes only.
- **Marketing** (source template 1 as base): home `#pricing` section — heading
  "Choose your plan", segmented toggle, three cards per family, footer links.
- **In-app** (source template 2, lighter chrome): `/billing` renders the same
  toggled component.

## Toggle mechanism

CSS-only radio + `has-[]` selector (the technique the source templates use):
zero JS, works identically on the static marketing controller page and inside
the `/billing` LiveView. Styled as a daisyUI segmented control. Default
selected: One-time.

## Stripe integration (real payments, test mode)

Deliberately overrides two CLAUDE.md "out of scope" rules — *real payment
vendors* and *webhooks* — at the user's explicit request. Card data is never
touched by our app (Stripe-hosted Checkout → PCI SAQ-A).

**Library:** add `stripity_stripe`.

**Adapter seam (anti-corruption layer).** Extend `Billing.Provider` with:
- `@callback create_checkout_session(attrs)` — `attrs` carries `mode`
  (`:payment` for credit packs, `:subscription` for plans), the Stripe
  `price_id`, `quantity`, `customer` info, and success/cancel URLs; returns
  `{:ok, %{checkout_url: ..., session_id: ...}}`.
- `@callback construct_webhook_event(raw_body, signature)` — verifies the
  Stripe signature and returns a normalized, atom-keyed event
  (`%{type:, session_id:, customer_id:, ...}`) with no Stripe structs leaking.

`Billing.StripeAdapter` implements both via `stripity_stripe`. `StubAdapter`
gains deterministic versions (fake `checkout_url`, locally-built events) so
dev/test never hit the network. Selected via `:billing_provider` config —
`StubAdapter` in dev/test, `StripeAdapter` when configured.

**Context API (business-readable, `Billing`):**
- `checkout_credit_pack(user, pack_key)` — `:payment` session for a one-time pack.
- `checkout_subscription(user, plan_key)` — `:subscription` session for a plan.
- `fulfill_checkout(event)` — idempotent fulfillment inside `Ecto.Multi`:
  for a pack, `Credits.grant/3` the pack's review-credits; for a subscription,
  upsert the `Subscription` (provider IDs, status, period end). Idempotency via
  a stored `provider_session_id` so duplicate webhooks are no-ops.

**Web:**
- `CheckoutController` (browser, authenticated) — `POST /checkout/credits/:pack`
  and `POST /checkout/subscription/:plan` create a session and redirect to
  Stripe; `GET /checkout/success`, `GET /checkout/cancel` land pages.
- `StripeWebhookController` — `POST /webhooks/stripe`, its own pipeline with a
  **raw-body reader** (cache raw body for signature verification) and **no
  CSRF**; verifies signature, calls `fulfill_checkout/1`, returns `200`.
- Pricing buttons POST to the checkout routes with the pack/plan key.

**Config / env (via `runtime.exs`, like the OAuth creds):**
`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, and per-product price IDs
(`STRIPE_PRICE_PACK_1`, `_PACK_3`, `_PACK_10`, `STRIPE_PRICE_SUB_STARTER`,
`_PRO`, `_ADVANCED`). `Billing.Prices` entries carry an env-var name → resolved
`price_id`. When keys are absent (default dev), provider stays `StubAdapter`.

**Stripe-side setup:** a `mix stripe.sync_products` task creates the 6
products/prices in the connected test account and prints the IDs (so we don't
hand-create them). Local webhook delivery uses the Stripe CLI
(`stripe listen --forward-to localhost:4000/webhooks/stripe`).

**Subscription plan atoms.** New plan keys (`starter`/`professional`/`advanced`)
are added to the `Subscription.plan` enum and `Credits.Tier` allowances
(starter→10, professional→30, advanced→100 monthly review-credits; 1 review =
10 credits) via a migration; `free`/`standard`/`pro` retained for back-compat.

## Needed from you

- A Stripe **test** secret key (`sk_test_…`) and webhook signing secret
  (`whsec_…`), provided via env. Everything builds against env now and stays
  inert (StubAdapter) until the key is present — same as the OAuth buttons.
- Running `stripe listen …` locally to exercise the webhook end-to-end.

## Scope boundaries

- **Test mode only** this pass; live is an env swap later. No saved cards,
  no customer portal, no proration/upgrade-midcycle math beyond create/cancel.
- Not building dunning, invoices UI, or tax. Refunds out of scope.

## Testing

- `Billing.Prices` config: both catalogues present, expected counts, exactly one
  `popular?` per family, price labels formatted, every entry resolves a price-id key.
- `Billing.Provider` via `StubAdapter`: checkout session + webhook-event shape.
- `Billing` context: `checkout_credit_pack` / `checkout_subscription` build the
  right session attrs; `fulfill_checkout` grants credits / upserts subscription
  and is **idempotent** on a repeated event (uses a mock/stub adapter — no network).
- `StripeWebhookController`: rejects a bad signature (`400`), fulfills a good
  event (`200`), and is idempotent on replay.
- `PricingComponents` render: both families render three cards; popular card
  carries the highlight class; toggle markup present; no "Refine" string leaks.
- `/billing` LiveView smoke: renders both families and the toggle.
