# Design: Regional (cost-of-living) & Promotional Pricing, Arbitrage-Hardened

**Date:** 2026-06-06
**Status:** Draft for review
**Context:** Pricing today is USD config-as-code in `PerfectPaper.Billing.Prices` (subscription plans + credit packs), rendered inline on the home page and in `billing_live`. Payments are the stub adapter (no real charge yet). Enterprise orgs are on negotiated contracts (out of scope here).

**Supersedes:** the credit-pack lineup + Stripe `price_env` set in `docs/superpowers/specs/2026-05-30-pricing-toggle-design.md` (`:pack_1/:pack_3/:pack_10`). This spec is the canonical catalogue: `:credit_single/:pack_3/:pack_6/:pack_12`. Retire `STRIPE_PRICE_PACK_1`/`_10`; add `_PACK_6`/`_PACK_12`/`_CREDIT_SINGLE`. The implementation plan must reconcile both specs so no third catalogue (e.g. `billing_live`'s current hardcoded 1/3/10) survives.

## Summary

Show and charge cost-of-living-adjusted prices by country, plus an annual-billing discount, communicated as struck-through prices in the marketing pricing UI — and make it **hard to arbitrage**. Display uses a spoofable signal (Cloudflare `CF-IPCountry`); the binding charge uses the payment method's country; every discounted decision is logged verbosely for after-the-fact scrutiny and never blocks the transaction.

## Decisions (locked during brainstorming)

- **Bands (4), by World Bank income group** — applied verbatim, **no generosity overrides** (so recently-high-income EU states like Romania/Poland/Czechia = Band A):
  - **A = 100%** (high income): US, Canada, UK, Germany, France, Netherlands, Italy, Spain, Nordics, Australia, Japan, and all EU high-income incl. Poland/Czechia/Romania.
  - **B = 75%** (upper-middle): Mexico, Brazil, Turkey, Russia, China, Argentina, Colombia, Malaysia, Thailand, South Africa, Serbia.
  - **C = 50%** (lower-middle): India, Indonesia, Philippines, Vietnam, Egypt, Ukraine, Morocco, Nigeria.
  - **D = 35%** (low income): Ethiopia, DRC, Uganda, Afghanistan, etc.
  - For the 12 shipped locales this lands as: A — en/en-GB/de/fr/fr-CA/es/nl/it/ro; B — es-MX, ru; C — hi; D — none.
  - A `country → band` map is config-as-code, sourced from the World Bank income-group list; document the source + a review cadence.
- **Two discount axes, stacked, shown as struck-through prices in the pricing cards** (no separate banner):
  - **Regional** (subscriptions + credit packs).
  - **Annual** (subscriptions only): annual = 10 months' price for 12 months of service.
  - Band A tops out at **1** discount (annual only). Bands B–D top out at **2** (regional always; + annual when yearly chosen).
- **USD only** (no FX/local currency).
- **Display country = `CF-IPCountry`.** **Binding charge country = payment method's country.**
- **Charge multiplier = the *less generous* of {IP-country band, payment-country band}** (i.e. `max(multiplier_ip, multiplier_payment)`). The transaction **always proceeds** at the resolved price — arbitrage simply yields no discount benefit; nothing is blocked.
- **Verbose, append-only audit** of every discounted decision; suspicious ones are **risk-flagged, not denied**.
- **Scope:** subscriptions (monthly + annual) and credit packs. Enterprise/org contracts excluded.

## Catalogue numbers — single source of truth (prerequisite)

`Billing.Prices` today stores prices as **display strings** (`price_label: "$40"`, `"$49.99"`, `"$299.99"`) plus the Stripe `:price_env` ids; the only numeric cents live hard-coded in view code (`billing_live.ex`, `page_html.ex`). The band math needs *numbers*. To avoid a second source of truth (CLAUDE.md "one rule in one place"):

- **Extend `Billing.Prices`** so each product map carries an integer **`list_cents`** (subscriptions: monthly list cents `M`; packs: list cents `L`) alongside the existing keys. `Prices` remains the sole catalogue of base numbers.
- **`Billing.Pricing` reads `list_cents` from `Prices`** and applies band/volume/annual math; it never re-parses `"$40"` and never holds its own copy of base prices.
- **All money is integer cents end-to-end** (no floats/`Decimal` in the hot path). A shared `Billing.Pricing.format_cents/1` derives the display string (`"$40"`, `"$19.99"`) so `Prices` and the view layer format one way. `0.35`/`0.75`/`0.83`/the annual factor are applied as integer-safe ratios (e.g. `div(cents * 35, 100)`), rounded once.

## Pricing math (round once, at the end)

All values are **integer cents**. Let `M` = a plan's `list_cents` (Band A monthly, from `Prices`). `b(country)` ∈ {1.0, 0.75, 0.5, 0.35} applied as an integer ratio. `floor` = a minimum cents per product to avoid degenerate amounts — concrete defaults (tunable config in `Pricing`): subscription monthly `floor = 500` ($5), `floor_annual = 5_000` ($50), credit pack/single `floor = 999` ($9.99). At Band D these floors don't bind for current prices but guard against future low-priced products. Round to a psychological value (nearest whole dollar / `…99` style) **after** the single multiply — never round intermediate steps. `round_psych/1` is a pure, idempotent function of cents (`round_psych(round_psych(x)) == round_psych(x)`).

**Subscriptions:**
- `monthly_price   = round_psych(max(M * b, floor))`
- `monthly_list    = M`  (struck only when `b < 1`)
- `annual_price    = round_psych(max(M * 10 * b, floor_annual))`   (`@annual_months_charged = 10` → 12 served; name the constant in `Pricing` so the idempotence test references it)
- `annual_list     = round_psych(M * 12 * b)`  (always struck — annual always saves two months)

Worked example, Starter `M = $40`:

| Band | Monthly card | Annual card |
|------|--------------|-------------|
| A (US/CA/W.Eu) | `$40/mo` (no strike) | ~~$480~~ **$400/yr** |
| B (×0.75) | ~~$40~~ **$30/mo** | ~~$360~~ **$300/yr** |
| C (×0.5) | ~~$40~~ **$20/mo** | ~~$240~~ **$200/yr** |
| D (×0.35) | ~~$40~~ **$14/mo** | ~~$168~~ **$140/yr** |

**Credit packs / single credit — this RESTRUCTURES the catalogue (deliberate, scoped here):**

The current `Prices.credit_packs/0` ships `:pack_1` / `:pack_3` / `:pack_10` (1 / 3 / 10 reviews). Phase 1 **replaces that lineup** with:

| Key | Reviews | Role | Volume `v` | New Stripe env |
|---|---|---|---|---|
| `:credit_single` | 1 | inline global top-up (not a card; "buy one more review" when out of credits) | 1.0 | `STRIPE_PRICE_CREDIT_SINGLE` |
| `:pack_3` | 3 | bundle | 1.0 | `STRIPE_PRICE_PACK_3` (reuse) |
| `:pack_6` | 6 | bundle | 1.0 | `STRIPE_PRICE_PACK_6` (new) |
| `:pack_12` | 12 | bundle (best value) | **0.83 (17% off)** | `STRIPE_PRICE_PACK_12` (new) |

This is a real catalogue change with Stripe `price_env` implications (new price ids `STRIPE_PRICE_PACK_6` / `STRIPE_PRICE_PACK_12` must be provisioned before Phase 2's real charge; the stub doesn't need them). Each entry gains an integer `list_cents` in `Prices` (the single numeric source). The old `:pack_1`/`:pack_10` keys are retired/renamed — call this out in the implementation plan so no view code references the dead keys (the only consumer today, `demo_live/billing.ex`, iterates `credit_packs/0` generically, so the rename is structurally safe).

**`:credit_single` routing:** it is a separately-keyed **inline** product (rendered at the point of "out of credits", not as a pricing-bundle card), so `Prices.credit_packs/0` returns only the three *bundles* (`:pack_3/:pack_6/:pack_12`); `:credit_single` is exposed via its own `Prices` accessor and priced through the same `pack_price_for/2` with `v = 1.0`. This keeps the bundle list (which the demo billing view iterates) to actual cards.

> ✅ **Prices APPROVED** (product-owner sign-off, 2026-06-06). Note for the changelog/marketing: vs. today's `:pack_3 = $119.99` / `:pack_10 = $299.99`, this **raises the 3-pack to $149.99**, **removes the 10-pack**, and adds 6- and 12-packs.

**Pack `list_cents` (Band A, before band/volume).** Per-review base = `$49.99`; the single + 3 + 6 are **flat per review** (no volume discount — only the largest is discounted); only `:pack_12` gets the 17%:

| Key | Reviews | `list_cents` (Band A) | `v` | Band-A displayed |
|---|---|---|---|---|
| `:credit_single` | 1 | `4999` ($49.99) | 1.0 | $49.99 |
| `:pack_3` | 3 | `14999` ($149.99) | 1.0 | $149.99 (no strike) |
| `:pack_6` | 6 | `29999` ($299.99) | 1.0 | $299.99 (no strike) |
| `:pack_12` | 12 | `59999` ($599.99) | 0.83 | ~~$599.99~~ **$499.99** (17% off) |

- `pack_price = round_psych(max(L * b * v, floor))` where `L` = the pack's `list_cents`, `v` = volume multiplier (only `:pack_12` is `0.83`). Struck-through original shown only when the displayed price is below `L` (always for `:pack_12`; for the others only when a region band discounts them). **Invariant: the displayed/charged price is always `≤ list`** — `round_psych` must never round a discounted value up past its list (clamp); this is a property test, not just the floor check. No annual axis on packs.

## Architecture

The **`Billing`** context owns this (it owns the vendor-agnostic pricing/charge contract). New pieces:

### Pure core — `PerfectPaper.Billing.Pricing` (config-as-code, no IO)
The pricers are keyed on a **resolved band**, not a country — so the same functions serve both display (one country → its band) and charge (two countries → the less-generous band). Country→band resolution and the two-country rule live in thin helpers; the math takes a band.
- `bands/0` → `[%{key: :a|:b|:c|:d, bps: 10_000|7_500|5_000|3_500, label}]` (multiplier as **basis points integer** — the single canonical unit everywhere; no float ratios). `country_band/1` (ISO-3166 alpha-2 → band key, default `:a` for unknown/`nil` — safe/least-discount). `resolve_band(ip_country, payment_country)` → the **less-generous** of the two (the band with the larger `bps`); a single-country call resolves against itself.
- `price_for(plan, band, cadence)` → `%{monthly_price, monthly_list, annual_price, annual_list, struck?, band, bps}` (all integer cents).
- `pack_price_for(pack, band)` and `unit_price_for(band)` (the inline single credit) → `%{price, list, struck?, volume_discount?, band, bps}`.
- `format_cents/1`, `floor`s, `round_psych/1` helpers. Pure, fully unit-tested incl. the worked tables and the `round_psych(round_psych(x)) == round_psych(x)` and `price ≤ list` (see Pricing math) properties.

### Web display — the REAL surfaces (corrected)
The live pricing UI is **not** the `pricing_components.ex` `pricing_tiers/1` block (that component is unused by the home page). Two surfaces actually show prices and both must be banded:
1. **Marketing home `#pricing`** — inline in `lib/perfect_paper_web/controllers/page_html/home.html.heex` (`:for={product <- Prices.list()}`, formatted by `page_html.ex` `plan_name/1`/`plan_price/1`). `PageController.home/2` currently does a bare `render(conn, :home)` — it must assign the resolved band so the section can render banded/struck prices.
2. **Authenticated billing `billing_live.ex`** — the actual purchase surface (LiveView). Its subscription cards render `plan_price(@product)` (raw label) and its credit-pack cards are **hardcoded + "Coming soon" disabled** (`price_cents={499/1299/3999}`). Both must be replaced with catalogue-driven, band-aware cards, and the pack section enabled and wired to the new `:credit_single/:pack_3/:pack_6/:pack_12` lineup.

- **Shared `CF-IPCountry` reader (DRY):** `FetchCookieConsent` already delegates country parsing to the `Compliance` context; only `cookie_consent_controller` still has its own copy of the `["", "XX"]` guard. So put the shared reader **in `Compliance`** (where the consent logic already lives — `Compliance.country_from_conn/1`), have the controller and this new pricing plug both call it, and do **not** create a separate `PerfectPaperWeb.RequestCountry` module (that would be a redundant home for logic the context already owns).
- **`PerfectPaperWeb.Plugs.FetchPricingCountry`** (in `:browser`): uses the shared reader, assigns `:pricing_band`/`:pricing_country` **and writes the resolved band into the session** (like `FetchLocale` does for locale). LiveView `mount/3` runs twice — the disconnected render has the conn assigns, but the **connected** WebSocket mount does not. So `billing_live`'s connected mount reads the band from the **session** (single, deterministic mechanism), with `get_connect_info(socket, :x_headers)` `cf-ipcountry` as a fallback if the session is empty — it never relies on a transient conn assign surviving the reconnect. State this one mechanism explicitly; don't hand-wave "session/get_connect_info" as if interchangeable.
- **Shared banded pricing card = a pure function component** (new, e.g. `PerfectPaperWeb.PricingComponents.plan_card/1` + `pack_card/1`) consumed by **both** `home.html.heex` and `billing_live.ex` so there is one renderer. It takes the band + both cadence variants pre-rendered.
- **Monthly/annual toggle:** driven client-side with **`Phoenix.LiveView.JS` show/hide** (both cadence variants server-rendered; the toggle flips a class). This works identically in the dead view (home) and the LiveView (billing) with **no `@cadence` server state** — so no reconnect state to lose, and one implementation for both surfaces. (`JS` is already used this way in `core_components.ex`.)
- The hardcoded prices in `home.html.heex`/`page_html.ex`/`billing_live.ex` are **removed**; every number derives from `Prices` via `Billing.Pricing`. Regional note "NN% lower for your country", "17% off — best value" on `:pack_12`, all via `gettext` (see localization note). Reduced-motion, sentence case, no emoji, daisyUI/paper theme.
- **EU Omnibus guard (Phase 1, not deferred):** the **regional** struck-through is a *synthetic* full price the visitor never could have paid in their region — under the EU Omnibus Directive a struck "previous price" must be a genuine prior selling price, so showing it to EU consumers is a dark-pattern violation, and the struck UI ships in Phase 1. Therefore: **for EU/EEA visitors, suppress the regional strike** — show only the discounted price (optionally an unstruck "regional pricing" label). The **annual** strike (annual vs. paying monthly × 12) *is* a genuine saving and stays. Non-EU markets may show the regional strike. **"Is this visitor EU/EEA" is orthogonal to band** (Band A deliberately mixes US + EU high-income states), so it cannot come from `country_band/1` — add a new country-set predicate **`Compliance.eea?/1`** (alongside the existing `Compliance.united_states?/1`), consumed by the pricing card to decide strike suppression. (Legal to confirm the exact EEA country set; the safe default ships now.)

### Charge seam (Phase 2 enforcement; seam built in Phase 1)
- `Billing.resolve_charge(user, product, cadence, ip_country, payment_country, idempotency_key, opts \\ [])` → resolves `band = Pricing.resolve_band(ip, payment)`, prices via `price_for/pack_price_for/unit_price_for(band, …)`, and performs the **purchase as a single `Ecto.Multi`** (CLAUDE.md law 8): persist subscription/cadence-or-pack-order + grant credits + append the `PricingAudit` row, committed together so a partial purchase is impossible. Returns the binding price. Always proceeds.
- **Idempotency (§11 — a double-click / reconnect must not double-charge or double-grant):** the purchase carries an **idempotency key** (client-supplied or derived from `{user_id, product, cadence, period}`) backed by a **DB unique index** on the orders/grants table; a retry hits the constraint and returns the original result via `*_constraint/3` on the changeset (NOT a check-then-act). On the stub this prevents double-granting 12 credits; in Phase 2 it prevents a double charge. The `PricingAudit` append is part of the same `Multi`, so audit and money never disagree.
- **`billing_live.ex` wiring (signature changes — call out):** `Billing.upgrade_plan(user, plan)` (arity-2) becomes `upgrade_plan(user, plan, cadence, applied_cents)` (or takes the `resolve_charge` result); `Subscription.create_changeset`/`change_plan_changeset` must cast `:interval` + the applied cents. The new pack-purchase event must use `String.to_existing_atom/1` guarding for the new keys `:credit_single/:pack_3/:pack_6/:pack_12` (matching the existing `billing_live` plan-atom safety). While rewriting these cards, **fix the stale "10 credits per review" copy** (`@proofreading_cost = 1` — it's 1 credit/review). On the **stub**, `resolve_charge` runs end-to-end (band, audit, persisted cadence) but moves no money; `payment_country` is `nil` → Band A for the *binding* number (display still shows the IP discount). Phase 2 supplies `payment_country` from the real payment method and enables the binding discount.

### Annual subscription entitlement (cadence + credit grant)
Today `Subscription` has **no interval field** and credits are granted **monthly** by `Credits.grant_monthly_allowance/3` (idempotent per `YYYY-MM`). Adding an annual plan requires:
- **Schema:** add `field :interval, Ecto.Enum, values: [:month, :year], default: :month` to `Subscription` (additive, nullable→default; safe migration, std 4). The applied band/cadence resolved at purchase are persisted alongside.
- **Entitlement (decided: lump sum):** an **annual** subscription grants **12 × the plan's monthly allowance once, up front, at purchase** — a new `Credits.grant_annual_allowance/2` that is **idempotent per subscription term** (dedup key `annual_allowance:{subscription_id}:{term_start}`), NOT per calendar month.
- **Drip-suppression mechanism (REQUIRED — the gate needs the data):** the monthly drip fires from `Credits.grant_monthly_allowance_for_event/1`, which today receives an `Events.Event` whose `data` is only `%{plan, status}` (emitted in `Billing.upgrade_plan`) — `interval` is **not** in the payload, so a naive `interval == :month` gate has nothing to read and the annual sub would get **12 lump + 12 drip**. So this is an explicit deliverable: **add `:interval` to the `subscription.updated` event `data`** AND have `grant_monthly_allowance_for_event/1` read it (or load the subscription) and **skip the grant when `interval == :year`**. Without both halves the double-grant returns.
- **Rollover/expiry:** the existing ledger already rolls credits over (no monthly expiry), so a lump-sum-12 simply sits in the balance. **Abuse note:** "buy annual, burn all 12, cancel/refund" is a real vector — annual is paid in full up front (no mid-term free burn), and a refund must claw back unused credits (`Credits.convert`/negative grant); flag for the Phase-2 refund path.
- **Tests:** annual sub grants exactly 12× once (idempotent on re-trigger); monthly drip is suppressed for annual; mixed re-runs don't double-grant.

### Enterprise / org exclusion — guarded, not incidental (C5)
"Enterprise excluded" must be an **explicit guard**, not an accident of code paths. Org-funded reviews charge via a different path entirely (`History.charge_for_level(%{owner_type: :group})` → `Organizations.charge_pool/2`, funded by `Billing.issue_invoice` at `price_per_seat_cents`) — that path **never** touches `Pricing`/`resolve_charge` and is out of band for regional pricing. Conversely a personal subscription/pack purchase **does** go through `resolve_charge`. Make it impossible to cross the streams:
- `resolve_charge` is **personal-path only**; it takes a user (not an org/group). Add a guard that raises/`{:error, :org_purchase_unsupported}` if called for a group-owned/org context, with a test.
- State in §Out-of-scope that org pool funding is never regionally adjusted (org contracts are negotiated; seat price is per-contract).

### Anti-arbitrage + audit
- **`PerfectPaper.Billing.PricingAudit`** — **decision facts are immutable** (`inserted_at` only, no `updated_at`; the country/band/cents/cadence facts are written once and never updated/deleted). The **risk columns are explicitly nullable and *set-once*** — written synchronously at insert in the default (inline-risk) path, OR, in the deferred path (line above), enriched **exactly once** by the Oban job via a guarded `UPDATE … SET vpn? = …, risk_score = … WHERE id = $1 AND risk_score IS NULL` (the `IS NULL` guard makes a retry a no-op, so a set-once write can't be rewritten). This is not a mutable-history update, so no `updated_at` is added; "append-only" applies to the decision facts. Columns: `id :binary_id` PK; `user_id` nullable `references(:users, type: :binary_id, on_delete: :nilify_all)` (audit rows outlive a deleted user); `ip_country`, `payment_country`, `locale`, `applied_band` (strings); `product` (string key); `cadence` (string); `list_cents`, `applied_cents` `:integer`; `applied_multiplier` `:integer` (basis points, e.g. `7500`, to stay integer); `vpn?`, `datacenter?` `:boolean`; `account_country_history` `{:array, :string}, null: false, default: []` — a **point-in-time snapshot** of the account's prior decision countries (not a maintained/back-filled list). Building it reads prior `PricingAudit` rows then appends a new one — a read-then-write. For the rapid-country-switch flag to be reliable under concurrent purchases by the same user, do this read+append inside the **same per-user advisory lock `Credits` uses** (`pg_advisory_xact_lock(hashtext(user_id))`); otherwise state explicitly that the history is best-effort/eventually-consistent and the switch flag may miss a simultaneous race; `mismatches` `{:array, :string}, null: false, default: []`; `risk_score :integer`; `inserted_at`.
  - **Migrations (zero-downtime, std 4):** (1) `create table` — brand-new table, safe in a normal migration; array columns typed with `default: []`. (2) **Separate** migration for the operator-review indexes, created **`concurrently`** with `@disable_ddl_transaction true` + `@disable_migration_lock true`: an index on `inserted_at` and a **partial index** `where: fragment("risk_score > 0")` (or on `mismatches != '{}'`) so the "show me flagged decisions" query is cheap without scanning the full log. Explicit `up`/`down`.
  - Context API: `Billing.record_pricing_decision/1` (append; total — never raises on the happy path), `Billing.list_pricing_decisions/1` (review/filter by user/flagged/date). Never blocks a transaction. **The operator/filter surface is platform-admin-gated at the web layer** (mirroring `Billing.create_contract`'s gating note) — `PricingAudit` is PII + a movement profile, so an unguarded operator query is an IDOR/§12 risk; the DSAR `list_pricing_decisions(user_id: …)` accessor is the user-scoped exception.
- **`PerfectPaper.Billing.RiskSignals`** behaviour + config-selected adapter (`:pricing_risk_provider`), default `RiskSignals.Stub` (basic datacenter-ASN check / no-op). Explicit contract:
  ```elixir
  @callback check(ip :: String.t(), opts :: keyword()) ::
              {:ok, %{vpn?: boolean(), datacenter?: boolean(), asn: integer() | nil, source: atom()}}
              | {:error, term()}
  ```
  The adapter **must enforce a tight timeout** (e.g. `Req` `receive_timeout: 300ms` / `Task.yield/2` bound) so a hung lookup cannot stall checkout. A **circuit breaker** (§6: repeated `{:error,_}` short-circuits without calling out) is **Phase 2** — it needs supervised cross-call state (ETS/`:persistent_term`) that Phase 1 doesn't stand up; the 300ms timeout bounds Phase-1 blast radius, and the stub never fails. The context treats `{:error,_}`/timeout/open-breaker as `risk_unknown` and proceeds (flag-don't-block). **If even 300ms on the checkout path is unacceptable, the risk lookup is deferred post-commit** (an Oban job on `:notifications`/`:maintenance` enriches the audit row's risk columns once — those columns are *set-once async*; the immutable decision facts — country/band/cents/cadence — are written synchronously in the `Multi`). Atom-keyed map; no vendor specifics leak past the adapter (anti-corruption layer per CLAUDE.md).
  - **Adapter selection (single rule):** `adapter = opts[:risk_signals] || Application.get_env(:perfect_paper, :pricing_risk_provider)`. The config default matches how `Chatbot` selects its provider (`Application.get_env(:perfect_paper, :llm_provider)`); the `opts[:risk_signals]` override is a test-injection superset of that (config-only in production).
- **Risk flags computed per decision:** IP↔payment band mismatch; VPN/datacenter; rapid country switching; discount-band drift across the snapshot `account_country_history`. Stored on the audit row; surfaced for scrutiny; **flag-don't-block**.

## Privacy & data protection (PricingAudit is PII — this is the GDPR worktree)

`PricingAudit` stores `user_id` + `ip_country` + `payment_country` + `account_country_history` (a movement profile) + `risk_score` (profiling). That is personal data and profiling under GDPR, in the branch whose whole point is EU compliance. This is a **required** part of the spec, not deferred:

- **Data minimization:** store **country codes only, never the raw IP** (the `RiskSignals` adapter receives the IP, returns flags; only the flags + country are persisted). `risk_score`/`mismatches` are coarse derived signals, not the underlying IP.
- **Lawful basis:** legitimate interest (fraud/arbitrage prevention) for the risk fields; document it.
- **Retention:** rows are **anonymized after 180 days** (configurable). **Required config deliverables (neither exists today):** add a `:maintenance` queue to `config :perfect_paper, Oban` (current queues `webhooks/documents/reviews/teams_notifier` don't fit a pruner) **and** add `Oban.Plugins.Cron` to the Oban `plugins` (only `Pruner` is configured now — without Cron the scheduled job never runs and PII grows unbounded, defeating the whole retention requirement). The job **batches** (keyset by `id` / `LIMIT`, looped until drained, with `lock_timeout`) — never one bulk `UPDATE … WHERE inserted_at < …` on a large append-only table (that's an unbounded lock-holding statement, §4/scale). It nulls `user_id`, `account_country_history`, and free-form fields, keeping only aggregate band/amount for analytics.
- **Erasure ≠ deprovisioning (don't conflate them):** the codebase's only soft-delete today is `Accounts.deactivate_user` — but that is **SCIM/directory deprovisioning**, NOT a user's right-to-erasure. Anonymizing the fraud audit on every routine deprovision would *destroy the anti-arbitrage record we built it for* (a deprovisioned employee is not an erasure request). So: add `Billing.anonymize_pricing_audit(user_id)` (nulls `user_id` + `account_country_history`), but call it from a **dedicated erasure step** (part of the planned DSAR/trust surface, sub-project E), **not** from `deactivate_user`. Until that erasure flow exists, this is a Phase-1 *hook* (the function + its test), wired into erasure when E lands. `on_delete: :nilify_all` is the hard-delete backstop. The spec must explicitly state deprovisioning leaves the audit intact.
- **DSAR / export:** pricing decisions for a user are **included in the data-export surface** (the planned trust-surface / sub-project E); `Billing.list_pricing_decisions(user_id: …)` is the accessor.
- **Art. 22 (automated decisions):** the design is **flag-don't-block with human review** — no automated decision produces a legal/significant effect on the user (a flag may prompt an operator, who is the decision-maker). State this explicitly; if flagging is ever wired to auto-deny a discount, that becomes an Art. 22 decision needing a DPIA + opt-out.
- **Transparency:** the **privacy policy** (`privacy.html.heex`, which already lists "IP address") gains a line covering geo-based pricing + fraud risk-scoring. This is a Phase-1 deliverable.

## Data flow

1. Request → `FetchPricingCountry` assigns IP band.
2. Pricing components render struck-through prices for that band (display).
3. At checkout → `Billing.resolve_charge` computes binding price from `max(ip_band, payment_band)`, persists applied band/cadence/price, and appends a `PricingAudit` row (with risk signals). Transaction proceeds regardless.
4. Operators review `PricingAudit` to spot abuse after the fact.

## Telemetry & observability (std 9)

The whole point is observable, scrutinizable pricing decisions — so metrics are first-class, not just the audit table:

- `:telemetry.execute([:perfect_paper, :billing, :pricing_decision], %{list_cents, applied_cents}, %{applied_band, product, cadence, mismatch?: boolean, risk_score})` — emitted on every `resolve_charge`. Lets dashboards/alerts watch discount mix and flag-rate without SQL-querying `PricingAudit`.
- `[:perfect_paper, :billing, :risk_signals, :start | :stop | :exception]` — a span (`:telemetry.span/3`) around the `RiskSignals` adapter call: duration + result (`:ok | :error | :timeout`), so the external boundary's latency/failure is visible (and the timeout above is measurable).
- These two events are **required deliverables**, wired into `PerfectPaperWeb.Telemetry` metrics alongside the existing ones.

## Error handling

- Unknown/missing `CF-IPCountry` → Band A (full price; safe default).
- Unknown payment country (incl. stub/`nil`) → Band A for the binding charge.
- `RiskSignals` adapter error/timeout → record `risk_unknown`, proceed (never block).
- Pricing math never returns below `floor`.

## Testing

- **`Billing.Pricing`** (pure, `async: true`): the full worked-example table (all bands × monthly/annual); `applied_multiplier/2` picks the less-generous; pack volume discount only on the 12-pack; floor + rounding in integer cents; unknown country → Band A; reads `list_cents` from `Prices` (no duplicated numbers). **Idempotence property:** `round_psych/1` and a re-resolved charge are stable — re-running `resolve_charge` on the persisted band yields the same `applied_cents` (no double-rounding).
- **`FetchPricingCountry`** (ConnCase, `async: true`): CF-IPCountry → band assign; `""`/`"XX"`/missing header → Band A (same guard as `FetchCookieConsent`).
- **Pricing components** (ConnCase, `async: true`): both cadence variants are server-rendered; Band A monthly has no strike; Band C monthly shows `list → price`; the annual variant is struck for all bands; the `Phoenix.LiveView.JS` toggle markup is present (assert the data/class hooks, not a server event); 12-pack shows the 17% label; strings gettext-wrapped (render a non-en locale to confirm localization).
- **`PricingAudit`** (DataCase, `async: true` — owns its sandbox connection): `record_pricing_decision/1` appends with all signals; mismatches/risk flags computed; `list_pricing_decisions/1` filters (incl. the flagged partial-index path).
- **Charge resolution + `RiskSignals`** (DataCase): **no Mox** (not a project dependency — don't add one, std 8). Follow the codebase's existing adapter-test convention. `RiskSignals` is config-selected (`:pricing_risk_provider`) like `Chatbot.LLM`; for async-safety, `Billing.resolve_charge/…` accepts the risk adapter as an **optional injected dependency** (`opts[:risk_signals]`, defaulting to the configured module) so a test passes a per-call stub module and stays `async: true` with **no global mutation** (std 5, functional-core injection). Stub modules (e.g. `RiskSignalsStub`, `RiskSignalsTimeout`) implement the `@behaviour` and return canned results — mirroring the `FailingLLM`/`RecordingStub` test stubs already in `test/support`. The only tests that swap global `Application.put_env(:pricing_risk_provider, …)` (e.g. asserting the default wiring) are `async: false`, exactly like `history_charge_on_success_test` does for `:llm_provider`. Cases: `resolve_charge` uses payment-country when less generous; persists applied band/cadence/cents; writes an audit row; injected stub `{:ok, %{vpn?: true}}` sets the flag; stub `{:error, _}`/timeout → `risk_unknown`, transaction still proceeds.

## Phasing

- **Phase 1 (shippable now):** extend `Billing.Prices` with integer `list_cents` + the restructured pack catalogue; `Billing.Pricing` band math (band-keyed, basis points, reads `Prices`); shared `Compliance.country_from_conn/1` reader + `Compliance.eea?/1` + `FetchPricingCountry`; the shared band-aware pricing card component wired into **both** `home.html.heex` and `billing_live.ex` (+ `PageController` band assign; enable + catalogue-wire `billing_live`'s pack section), `Phoenix.LiveView.JS` cadence toggle, struck-through + labels, localized; `Subscription.interval` field + annual lump-sum `Credits` grant (+ suppress monthly drip for annual); `resolve_charge` (personal-path-only guard) wired into `billing_live`'s purchase events against the stub; `PricingAudit` table + concurrent-index migration + context + the **180-day anonymizer Oban job** + deactivation-time anonymization; `RiskSignals` behaviour + stub adapter (timeout); the two `:telemetry` events; the privacy-policy copy update.
- **Phase 2 (with real payments):** payment-country input wired from the payment method; binding-charge enforcement; persist applied pricing on real orders/subscriptions; richer `RiskSignals` adapter.

## Out of scope

Local-currency/FX · enterprise/org-contract regional adjustment · blocking/denying transactions (we flag, never block) · pack annual axis · real payment integration (Phase 2 depends on it).

## Risks / watch-items

- **Arbitrage residue:** payment-country is the real guard; until Stripe (Phase 2) the *binding charge* can't verify it, so Phase 1 conservatively treats unknown payment country as Band A — display shows the discount, but no money moves at a discount yet. Make this explicit so Phase 1 isn't mistaken for "discounts are live and enforced."
- **Country→band map maintenance:** it's config; document the source (World Bank income groups) and review cadence.
- **VPN detection quality:** the stub is weak by design; real coverage needs a paid adapter — the behaviour boundary makes that swappable.
- **Rounding fairness:** round once at the end; verify no plan/band lands below floor, above list, or at an absurd value.
- **EU consumer-pricing law (assess before EU go-live):** struck-through "previous price" claims fall under the **Omnibus Directive** (the reference price must be genuine), and consumer prices in the EU generally must be **VAT-inclusive**. "USD adjusted amount, no FX" is fine for display now, but VAT-inclusive display + Omnibus compliance must be assessed before real EU charges (Phase 2). Ironic-but-real given this is the compliance worktree.
- **Localization of dynamic strings (gettext):** the regional note must use interpolation — `gettext("%{pct}% lower for your country", pct: …)` — not string-concat. Avoid needing translated **country names** (we have the ISO code, and per-country localized names aren't in the i18n surface): show "your country" / the code / a flag, not a translated country name. The numeric price itself is not translated (it's `format_cents/1` output).
