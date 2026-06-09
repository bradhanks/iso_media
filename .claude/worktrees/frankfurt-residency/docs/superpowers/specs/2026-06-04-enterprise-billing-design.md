# Enterprise Billing — seat-based org contracts + internal invoicing (Spec 4) — Design

**Date:** 2026-06-04
**Status:** Approved (pending written-spec review). Seat-based org subscription billed by **invoice/contract with NET terms**; no real payment processor this pass (the `Billing.Provider` stub remains for the individual card path). Extends the existing **`Billing`** context. Follows Spec 3a (SSO) + 3b (SCIM); seat counting is driven by SCIM-provisioned active membership.

## Why

Enterprise customers (a university, a department, a lab) buy PerfectPaper for a *team*, not as individual professors each holding a personal subscription. They procure via a **contract** (negotiated seat count + per-seat price + annual/monthly term + PO + NET-30), expect **invoices** (not a credit-card charge), and expect **frictionless onboarding** (adding people must never be blocked by a seat cap mid-rollout). Billing today is per-`user` only; orgs have a `credit_pool` with no funding source. Spec 4 fills that gap: org-level seat billing that funds the pool, with soft overage so SSO/SCIM provisioning is never blocked.

## Locked decisions (brainstorming)

| Decision | Choice |
|---|---|
| Billing model | **Seat-based org subscription.** Billable seats = active org members (SCIM-driven). Each seat carries a monthly review allowance that funds the org credit pool. |
| Collection | **Invoice / contract, NET terms.** Contract: seats, per-seat price, interval, PO, net-terms. Invoices are **internal AR records** (issued → paid → overdue → void); no card, no external processor. |
| Seat handling | **Contracted seats + soft overage.** Provisioning is **never blocked**. Seat overage (active above contracted) is trued-up on the next invoice using a **high-water mark**, never point-in-time. |
| Boundary | **Extend the `Billing` context** (it owns the provider contract + per-user subscriptions). New `Billing.Contract` + `Billing.Invoice` schemas. |
| Coexistence | Per-user subscriptions are **unchanged**; an individual's personal subscription is **never auto-canceled**. Usage is resolved by **session ownership** (org-owned vs personal). |

## Architecture

### Context boundary — extend `Billing`
`Billing` already owns the payment-provider contract (`Billing.Provider` + `StubAdapter`), per-user `Subscription`, `Prices` (config), and the notifier. Enterprise contracts + invoices are billing concerns → they live here. New schemas carry their own changesets per CLAUDE.md.

### Data model (migrations)

**`org_contracts`** (`Billing.Contract`):
- `id` binary_id; `organization_id` binary_id → organizations; `seats` integer (contracted, > 0); `price_per_seat_cents` integer (≥ 0 — the per-seat price for **one billing period**; enterprise pricing is negotiated, so it lives on the contract, not `Prices` config); `per_seat_credits` integer (≥ 0 — review allowance per seat for **one billing period**); `interval` `Ecto.Enum [:monthly, :annual]` (defines the length of a billing period; all per-seat values are period-relative, so a single cadence — invoice + pool funding — fires once per period with no ×12 math); `status` `Ecto.Enum [:draft, :active, :expired, :canceled]` (default `:draft`); `term_start` :date; `term_end` :date; `po_number` :string (nullable); `net_terms_days` integer (default 30); `peak_seats_used` integer (default 0 — high-water mark since last invoice); `created_by` binary_id; timestamps.
- **Partial unique index** guaranteeing at most one active contract per org: `create unique_index(:org_contracts, [:organization_id], where: "status = 'active'", name: :unique_active_contract_per_org)`. An org may hold any number of `:draft`/`:expired`/`:canceled` contracts but only one `:active`.

**`invoices`** (`Billing.Invoice`):
- `id` binary_id; `organization_id` binary_id; `contract_id` binary_id → org_contracts; `number` :string (UNIQUE — non-enumerable, see below); `period_start`/`period_end` :date; `seats_billed` integer; `seat_overage` integer (default 0); `amount_cents` integer; `funded_credits` integer (default 0 — **exact** credits this invoice added to the pool, so a later void claws back the precise amount even if `per_seat_credits` later changes); `status` `Ecto.Enum [:issued, :paid, :overdue, :void]` (default `:issued`); `issued_at`/`due_at`/`paid_at` :utc_datetime (paid_at nullable); timestamps. Index `[:organization_id]`, `[:status]`.

**`organizations`** — no new column; `credit_pool` is reused. **No DB CHECK constraint exists** on `credit_pool` (verified) — the non-negative invariant is an *Elixir* `pool_changeset` validation, and the funding/allocation paths use atomic `Repo.update_all(inc: …)` which bypasses the changeset entirely. So "relax under an active contract" is **code-level only** (no migration to drop a constraint); the `pool_changeset` guard stays for any changeset-based write, and allocation enforces the contract-aware floor explicitly.

### Seat counting (ties to SCIM 3b) — high-water mark
- **Current used seats** = count of `:active` memberships (`Organizations.active_member_count/1`, new).
- **`peak_seats_used`** on the active contract is the high-water mark since the last invoice. It is bumped **atomically on member activation** — `Billing` subscribes to the existing `:"member.provisioned"` and `:"member.reactivated"` events (3b). The count and the `GREATEST` comparison happen **in a single SQL statement** (never SELECT-count-in-Elixir-then-UPDATE, which races under concurrent bulk SCIM imports): `update: [set: [peak_seats_used: fragment("GREATEST(peak_seats_used, (SELECT count(*) FROM memberships WHERE organization_id = ? AND status = 'active'))", ^org_id)]]`, scoped to the org's `:active` contract. Postgres computes the count and applies `GREATEST` under the row write-lock, so a 50-user parallel import can't under-report the peak. (Point-in-time counting at invoice time is gameable — deactivate-before/reactivate-after — so we never use it.)
- **Seat overage** at invoice time = `max(0, peak_seats_used − seats)`. After issuing an invoice, `peak_seats_used` is **reset to the current active count**.
- **Peak *concurrent* seats, not unique users (confirmed model).** Deactivating user A then activating user B leaves the count unchanged — billing is on peak concurrent seats, so an org may recycle many people through a fixed seat count over a period. This is the standard SaaS interpretation and matches SCIM's active-membership signal exactly.
- **Annual-interval overage is trued up annually (accepted MVP limitation — Option A).** With `interval: :annual` the invoice fires once per year, so a transient mid-year spike (10 → 100 → 10) bills the **annual peak (100)** at year-end. Known and accepted: sales sets expectations, and orgs with variable headcount should choose `:monthly`. Per-month overage invoicing for annual contracts (a lightweight monthly peak check) is a future enhancement (Option B), noted as `TODO(billing)`.

### Credit allowance → org pool (atomic + idempotent + starvation-safe)
**Funding.** Each billing period, `issue_invoice` funds the pool by `billed_seats × per_seat_credits` (`billed_seats = max(seats, peak_seats_used)` — overage seats fund credits too, which is what actually relieves starvation). Funding is an **atomic increment**, never read-modify-write: `Repo.update_all(from(o in Organization, where: o.id == ^org_id), inc: [credit_pool: amount])`, and the exact amount is recorded as the invoice's `funded_credits`. **Idempotent per period** via a `last_funded_period` marker on the contract (at most one funding per `(contract, period)`).

**Allocation (hot path).** Members draw via `allocate_credits_to_member/3`, which runs constantly — so the contract is queried **only when the pool would actually go negative**:
1. *Fast path* — atomic conditional decrement in one statement, no contract query: `UPDATE organizations SET credit_pool = credit_pool - $amount WHERE id = $org AND credit_pool >= $amount`. If it affects a row → done.
2. *Slow path* — reached only when (1) affects 0 rows (would go negative): check `Billing.has_active_contract?(org_id)` (date-aware, see Contract lifecycle). If active AND the resulting balance stays **at or above the soft floor** `−(contracted_seats × per_seat_credits × 2)` (a 2-period buffer that caps the blast radius of a buggy script or compromised key), force the atomic decrement (the pool may go negative). Otherwise `{:error, :insufficient_credits}`.

Non-contract orgs never reach the slow-path allow-branch, so they can never go negative — the existing guarantee holds. Negative balance is prepaid-credit debt that self-corrects when the next period funds the pool. (`Organizations.fund_pool/2` + the contract-aware decrement encode this; the `pool_changeset` non-negative validation is untouched since these paths are raw atomic `update_all`.)

### Invoice lifecycle
- `Billing.issue_invoice(contract, period)` (one `Ecto.Multi`): creates an invoice — `seats_billed = seats`, `seat_overage = max(0, peak_seats_used − seats)`, `amount_cents = (seats + seat_overage) × price_per_seat_cents` (period-relative, no interval multiplier), `funded_credits = (seats + seat_overage) × per_seat_credits`, `status: :issued`, `issued_at = now`, `due_at = now + net_terms_days` — then **atomically funds the pool** by `funded_credits` and **resets `peak_seats_used`** to the current active count. Emits `:"invoice.issued"`.
- `Billing.mark_invoice_paid/1` → `:paid` + `paid_at` (privileged — internal/platform-admin, or a future processor). Emits `:"invoice.paid"`.
- An issued invoice past `due_at` with no payment is `:overdue` (derived in queries; persisting it is a future Oban sweep).
- `Billing.void_invoice/1` (one `Ecto.Multi`): sets `:void` AND **claws back the pool** by that invoice's recorded `funded_credits` (`update_all(inc: [credit_pool: -funded_credits])`). Without the clawback, issue→void would mint free credits. The clawback may drive the pool deeply negative — **correct and intended** when the org already spent credits it hasn't paid for.
- **Invoice number** is non-enumerable (tenants must not be able to guess volume): `INV-{YYYYMM}-{random}` where `{random}` is an 8-char uppercase Base32 slug (`:crypto.strong_rand_bytes` → `Base.encode32`), uniqueness enforced by the DB unique index with a regenerate-on-conflict retry.

### Contract lifecycle
- `Billing.create_contract(org, scope, attrs)` — inserts a `:draft` contract (seats, price, per_seat_credits, interval, term dates, PO, net terms). Creating/editing a draft and activating it are **internal/platform-admin only** (enterprise deals are sales-arranged with a signed agreement; org-admins *view* their billing but cannot self-activate a contract that bypasses legal/finance — see Web surface).
- `Billing.activate_contract/1` flips `:draft` → `:active` (the partial unique index enforces single-active; a concurrent second activation surfaces `{:error, :active_contract_exists}`), then issues the first invoice + funds the pool.
- `Billing.swap_active_contract(org_id, old_id, new_id)` — **atomic renewal** in one `Ecto.Multi`: expire the old `:active` contract AND activate the new `:draft` in a single transaction, so there is **never a zero-active-contract window** (in which a negative-pool org's users would be wrongly blocked mid-renewal).
- `Billing.cancel_contract/1` → `:canceled` (stops future funding; the pool keeps its current balance).
- **Active is date-aware — no cron dependency.** `Billing.has_active_contract?(org_id)` is true only when a contract is `status == :active` **AND** `term_start <= today <= term_end`. The instant `term_end` passes, the contract is treated as inactive at runtime — new negative-pool draws stop immediately — with **zero reliance on a background sweep**. A later Oban sweep may persist `:expired` cosmetically, but correctness never depends on it (so a stalled queue can't let an expired customer run up unbounded debt).

### Coexistence with per-user billing (resolve by session context)
- A personal `Subscription` is **never auto-canceled** when its user joins an org — the user may do personal/other-lab work outside the enterprise org.
- **Access resolves by session ownership** (sessions already carry `owner_type` + `organization_id`): a review on an **org-owned** session draws from that org's pool under its active contract; a review on a **personal** session draws from the user's personal subscription/credits. The existing `Authz`/session ownership is the discriminator — Spec 4 adds the billing-source resolution, not a new ownership concept.
- **Transparency:** the user settings/billing page shows which context is paying (e.g. "Org workspaces are covered by **[Org]**'s enterprise plan; personal workspaces remain on your individual tier").

### Provider / adapter
Real payment vendors remain **out of scope** (stub). Enterprise invoices need no processor (internal AR). `Billing.Provider` + `StubAdapter` are untouched and continue to serve the individual card path.

### Web surface
- **REST** — two gates:
  - *Org-admin, view-only* (gated via `Organizations.admin?`, OpenAPI): `GET /api/orgs/:org_id/billing/contract` (current contract + seats used/contracted/overage + pool status), `GET /api/orgs/:org_id/billing/invoices` (number, period, amount, status, due/paid). An org admin sees what they're billed — not edit/activate.
  - *Platform-admin, internal* (gated by the `admin_emails` allowlist — same gate as `/admin`): `PUT /api/orgs/:org_id/billing/contract` (create/edit draft), `POST .../contract/activate`, `POST .../invoices/:id/mark-paid`, `POST .../invoices/:id/void`. These privileged transitions never run on a tenant-self-serve route.
- **LiveView** — two surfaces:
  - *Org-admin billing dashboard* (`/orgs/:org_id/billing`, `Organizations.admin?`): contract terms, **seats used vs contracted (+ overage banner)**, credit-pool balance (incl. negative-overage state), invoice list with statuses + due dates. Read-only for the org.
  - *Internal billing admin* (`/admin/billing`, platform-admin `require_admin`): create/activate/swap contracts, issue/mark-paid/void invoices.
  - Both: discrete test ids, paper theme, no emoji, money formatted from cents.

### Events
New `Events.Event` types: `:"contract.created"`, `:"contract.activated"`, `:"invoice.issued"`, `:"invoice.paid"`. Emitted post-commit, `organization_id`-scoped → webhooks (Spec 8) + PubSub. (`seats.overage` is surfaced in the dashboard from the high-water mark; a discrete event is optional and deferred.)

## Security
- **Two gates:** *viewing* contract/invoices is **org-admin** (`Organizations.admin?`); *every mutation* (create/edit draft, activate, swap, mark-paid, void) is **platform-admin / internal** (`admin_emails` allowlist). Non-admin → 403, unknown org → 404 (reuse the SSO/SCIM REST posture).
- Privileged transitions (`activate`/`swap`/`mark-paid`/`void`) are never settable from a tenant-supplied field on create.
- Money is stored in **integer cents**, never floats; `amount_cents` and `funded_credits` are recomputed server-side from `seats × price` / `× per_seat_credits` — never trusted from the request.
- `status`, `peak_seats_used`, `number`, `amount_cents`, `funded_credits`, `paid_at` are context-maintained, never cast from request bodies.
- Negative-pool tolerance is gated on a **date-aware active contract** AND bounded by the soft floor `−(seats × per_seat_credits × 2)` — a non-enterprise org can never go negative, and even an enterprise org is capped.

## Testing
- **Contract schema/changeset**: required fields, positive seats, the **partial-unique active constraint** (two actives → DB error surfaced as `{:error, :active_contract_exists}`); status transitions.
- **Seat counting**: `active_member_count` matches `:active` memberships; `peak_seats_used` bumps on `member.provisioned`/`member.reactivated`, does NOT drop on deactivation, and **cannot be gamed** (activate 12 → deactivate 2 → invoice still bills peak 12); reset to current on invoice.
- **Atomic funding**: `fund_pool` increments correctly under concurrency (two simultaneous funds don't lose an update); **idempotent per period** (funding the same period twice grants once).
- **High-water concurrency + anti-gaming**: a burst of parallel `member.provisioned` events does not under-report `peak_seats_used` (single-SQL `GREATEST(…, (SELECT count …))`); activate 12 → deactivate 2 → invoice still bills peak 12; reset to current active on invoice.
- **Hot-path allocation**: the fast-path conditional decrement runs with **no contract query** when the pool is funded; the contract is queried only when a draw would go negative.
- **Starvation / negative pool + soft floor**: under a date-aware active contract, allocation drives the pool negative without blocking, but is **refused once it would breach `−(seats × per_seat_credits × 2)`**; the next period's funding restores it; a **no-contract** org (or a contract **expired by date**) still refuses to go negative.
- **Atomic renewal swap**: `swap_active_contract` expires the old + activates the new in one transaction — never a moment with zero active contracts.
- **Date-aware expiry**: a contract past `term_end` is NOT `has_active_contract?` even while `status == :active`, so negative draws stop with no sweep.
- **Invoicing**: `amount_cents = (seats + overage) × price_per_seat_cents`; `funded_credits = (seats + overage) × per_seat_credits` (pool funded by exactly that); `due_at = issued_at + net_terms_days`; overdue derivation; `number` unique + matches `INV-YYYYMM-…` + non-sequential; mark-paid sets `:paid`/`paid_at`.
- **Void clawback**: voiding claws back exactly the invoice's `funded_credits` (issue→void nets zero credits — no free-credit loophole), and may leave the pool deeply negative if already spent.
- **Coexistence**: a user with a personal subscription joining an org keeps the subscription (not canceled); an org-owned session draws from the pool, a personal session from the personal sub.
- **Web**: REST contract/invoice CRUD + activate + mark-paid (org-admin ok; non-admin 403; unknown org 404; amounts server-computed); LiveView dashboard renders seats used/contracted/overage, pool (incl. negative), invoice statuses.
- **Events**: `contract.activated`/`invoice.issued`/`invoice.paid` emitted post-commit (assert via `Events.subscribe`).

## Out of scope (this pass — TODO / later)
- Real payment processor / Stripe (stub only); card collection for orgs.
- Automated dunning / collections / reminder emails beyond the existing notifier.
- Tax / VAT, multi-currency (USD cents only).
- **Per-review usage-metered** overage billing — overage is **seat** true-up only (seats are the billing unit).
- Automated contract expiry / renewal jobs (status flips are admin/internal this pass; an Oban sweep is a follow-up `TODO(billing)`).
- Proration of mid-cycle seat *price* changes (high-water seat overage is trued-up at period end, not pro-rated daily).
- Multiple concurrent active contracts / multiple plans per org.

## Definition of done
- Migrations: `org_contracts` (+ partial unique active index `where status='active'`), `invoices` (incl. `funded_credits`). No DB-constraint change needed — pool non-negativity is code-level.
- `Billing.Contract` + `Billing.Invoice` schemas/changesets; `Billing` context: `create_contract`/`activate_contract`/`swap_active_contract`/`cancel_contract`, `has_active_contract?` (date-aware), `issue_invoice`/`mark_invoice_paid`/`void_invoice` (with credit clawback), seat/overage helpers, non-enumerable invoice numbering.
- `Organizations.active_member_count/1` + atomic `fund_pool/2`; hot-path contract-aware negative allocation bounded by the `−(seats × per_seat_credits × 2)` floor; `Billing` event-handler bumping `peak_seats_used` via single-SQL `GREATEST` on member activation.
- REST: org-admin **view** routes + platform-admin **manage** routes (OpenAPI); org-admin billing dashboard + internal `/admin/billing`.
- `contract.created/activated` + `invoice.issued/paid` events.
- Coexistence: personal subs untouched; usage resolved by session ownership; transparency copy on settings.
- Tests green (high-water anti-gaming + concurrency, atomic+idempotent funding, negative-pool soft floor, void clawback, atomic swap, date-aware expiry, server-computed amounts); `mix precommit` green.

## Resolved decisions (from review)
1. **Credit roll-over, not reset.** Funding **adds** (`inc`) each period; unused credits **roll over** with no expiry — enterprises treat prepaid credits as paid assets, and hard resets are a procurement-complaint source.
2. **Contract management is internal-only.** Org-admins **view** their contract + invoices; **creating/editing a draft, activating, swapping, mark-paid, and void are platform-admin (internal) only** — a contract reflects a signed agreement and must not be self-activated past legal/finance.
3. **Negative-pool soft floor = `−(contracted_seats × per_seat_credits × 2)`** (a 2-period buffer): generous enough that legitimate spikes are never blocked, bounded enough that a buggy script or compromised key can't drive the pool toward negative-infinity and corrupt analytics.
