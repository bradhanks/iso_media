# Design: Credit Gifting

**Date:** 2026-06-09
**Status:** Draft for review (rev 2 — incorporates a source-verified spec-editor pass: two missing API prerequisites surfaced, charge moved to the shell, `reviews` derived, redemption window enforced at redeem)
**Context:** Credits are an append-only ledger (`PerfectPaper.Credits`; `credit_events`, balance derived, per-user `pg_advisory_xact_lock`, `:paid`/`:preview` buckets, `metadata->>'dedup'` idempotency). Packs are bought via `Billing.start_pack_checkout/purchase_pack` (stub now, Stripe = Phase 2) which grants to the **buyer**. `Referrals` already models a code → claim → reward state machine. No user-to-user transfer or gift code exists today.

## Summary

A giver **buys a credit pack as a gift** and receives a shareable **bearer code/link**; a recipient **redeems it while logged in**. The purchased credits are **escrowed in a gift record** — never in anyone's balance — until exactly one terminal grant fires: to the recipient on redeem, or back to the giver on expiry. This keeps the ledger append-only with no reversing entries and no Stripe refund loop. Gifts are priced at **Band A** (anti-arbitrage) and the redemption window is **5 years** (gift-card-law safe), after which unredeemed value reverts to the giver.

## Decisions (locked during brainstorming)

- **Purchase-to-gift only.** The giver pays real money (stub now / Stripe Phase 2); credits are newly purchased, never moved from an existing balance. No laundering of free academic/referral credits.
- **Bearer code/link, mirroring `Referrals`.** Recipient redeems while logged in (signs up first if new). No recipient-directed email (avoids enumeration/spam); the giver shares the link however they like.
- **Band A pricing (anti-arbitrage).** A bearer code is resellable, so a low-band buyer could otherwise resell at a margin. Charging full Band-A price removes the margin. Recorded in `PricingAudit` like any pricing decision.
- **Escrow, not transfer.** The giver's purchase grants **no** credits. The pack size lives in the gift record. Exactly one terminal grant occurs (recipient on redeem, or giver on expiry) — ledger never double-counts, no refund needed for the common path.
- **5-year redemption window, revert-to-giver on expiry.** Satisfies the US CARD Act minimum; value is never destroyed (returns to the purchaser). Configurable (`@gift_ttl_days`, default 5 years).
- **Personal only.** No org/group pool gifting this pass.
- **Gifted credits land in the `:paid` bucket** and are independent of the academic signup gate — redeeming a gift cannot bypass or inflate the free-credit gate.

## Architecture

### New `Gifts` context

`lib/perfect_paper/gifts.ex` is the public API + sole `Repo`/IO boundary for the gift lifecycle (mirrors `Referrals`). It calls `Billing` (pricing + charge) and `Credits` (grant) **only through their public APIs** — never the ledger directly (CLAUDE.md law 1). `lib/perfect_paper/gifts/gift.ex` holds the schema + changesets.

### Prerequisites — two real API extensions (NOT zero-risk footnotes)

A spec-editor pass verified against source that gifting calls two functions that **do not exist today**. Both are explicit, tested prerequisites of this work, sequenced before the Gifts context:

1. **`Credits` — a public dedup-capable grant.** The current public `Credits.grant/4` is fixed-arity `(user_id, amount, reason, kind)` and accepts **no metadata or dedup key**; the dedup/metadata machinery (`locked_insert`/`granted_before?`/dedup-metadata) is **private**, used only by the campaign path. Gifting's terminal grants need both the `%{source, gift_id}` ledger trace and the `dedup` idempotency backstop. **Add a public grant that routes through the private `locked_insert` + dedup path** — e.g. `Credits.grant(user_id, amount, reason, kind, opts)` where `opts` carries `:metadata` and `:dedup` — with its own context tests. This is a genuine `Credits` API change, not an additive no-op.

2. **`Billing` — a charge-WITHOUT-grant port at a forced band.** Verified: no Billing function charges without also granting to the buyer — `purchase_pack` fuses `resolve_charge` + `Credits.grant(buyer)`, and `resolve_charge` derives the band/price from `ip_country` (it cannot be handed a forced Band A). The escrow model ("charge the giver, grant nobody, at Band A") has **no API to call**. **Add a charge-only entrypoint behind `Billing.Provider`** — e.g. `Billing.charge_gift(user, pack_key, idempotency_key)` — that prices `:pack_12`/etc. at the forced **Band A** via `Pricing.pack_price_for(pack_map, :a)`, records a `PricingAudit` row, threads `idempotency_key` into the provider callback (so a Phase-2 Stripe retry dedupes via the Stripe `Idempotency-Key`), and returns **without any `Credits.grant`**. Stub (Phase 1) records the audit + returns `{:ok, :charged}`; Stripe (Phase 2) returns a checkout reference and the webhook confirms.

### Data — the `gifts` table

`Gifts.Gift` (binary_id PK):

| Column | Type | Notes |
|---|---|---|
| `id` | `binary_id` | PK |
| `code_hash` | `:string` | **SHA-256 of the bearer token**; plaintext never stored. `unique_index`. |
| `giver_user_id` | `references(:users, type: :binary_id, on_delete: :nilify_all)` | gift outlives a deleted giver |
| `redeemer_user_id` | `:binary_id` (nullable) | set on redeem; `references(:users, on_delete: :nilify_all)` |
| `pack_key` | `:string` | `"pack_3" \| "pack_6" \| "pack_12"` (the existing catalogue) |
| `reviews` | `:integer` | credits granted on the terminal event. **Derived from `pack_key`**, never client-supplied (see below). |
| `amount_cents` | `:integer` | what the giver paid — **Band A** price, set-once |
| `status` | `Ecto.Enum, values: [:pending, :redeemed, :expired, :expired_forfeited, :refunded], default: :pending` | DB column `default: "pending"` in the migration |

**`reviews` is derived, not trusted.** The changeset sets `reviews` from `pack_key` via `Prices.credit_packs/0` (and validates `pack_key` is one of the three catalogue keys); inbound params never set `reviews` directly. Add a DB `CHECK` (or a changeset invariant) binding `reviews` to the `pack_key`'s catalogue value so a terminal grant can never pay out a forged amount.
| `idempotency_key` | `:string` | purchase idempotency; `unique_index` |
| `message` | `:string` (nullable) | optional giver note |
| `expires_at` | `:utc_datetime` | purchase + `@gift_ttl_days` (default 5 years) |
| `redeemed_at` | `:utc_datetime` (nullable) | |
| timestamps | | |

**Indexes (migration):**
- `unique_index(:gifts, [:code_hash])`
- `unique_index(:gifts, [:idempotency_key])`
- `index(:gifts, [:giver_user_id])` and `index(:gifts, [:redeemer_user_id])` — for the "sent / received" dashboards
- **Partial index for the expiry cron:** `create index(:gifts, [:expires_at], where: "status = 'pending'")` — keeps the index tiny (only the non-terminal rows) so the daily sweep never seq-scans. Mirrors the `pricing_audits_flagged_idx` pattern.

### State machine

`:pending` is the only non-terminal state. Every terminal transition is guarded by `status == :pending` under a row lock, so the grant fires **at most once** per gift. **Regenerate** (lost-token rescue, Flow D) is a `FOR UPDATE`-serialized `:pending → :pending` self-loop that only rotates `code_hash` — no grant, no terminal transition.

```
   ┌─ regenerate (rotate code_hash) ─┐
   │   (FOR UPDATE, no grant)        │
   ▼                                 │
:pending ───────────────────────────┘
   │
   ├── redeem (auth; expires_at > now) ─▶ :redeemed          grant → redeemer
   │
   ├── expiry sweep, giver live ───────▶ :expired            grant → giver
   │
   ├── expiry sweep, giver nil ────────▶ :expired_forfeited  (no grant)
   │
   └── giver cancels (Phase 2 refund) ─▶ :refunded           (no grant)
```

**The 5-year window is enforced at redeem, not by the cron.** Redeem rejects any gift whose `expires_at <= now` (treating it as expired) **regardless of whether the daily sweep has run yet** — so there is no ~24h cron-lag window in which an expired gift is still claimable. The cron is pure cleanup/revert: it flips lagging-expired `:pending` rows to `:expired` (granting the giver) on its own schedule, but redeem never honors an over-the-line gift in the meantime.

## Flows

### A. Purchase — `Gifts.purchase_gift(giver, pack_key, idempotency_key, opts)`

The charge is a **side-effect run in the imperative shell after the gift row is committed**, never inside the `Ecto.Multi` (an effect inside a transaction is the wrong shape — it can't be rolled back and the txn can't see whether it committed). Ordering matters for money safety: **insert first (claims the idempotency key), then charge.**

1. `pack_map = Enum.find(Prices.credit_packs(), & &1.key == pack_key)`; `reviews = pack_map.reviews`-equivalent derived from the catalogue; `price = Pricing.pack_price_for(pack_map, :a).price` (Band A).
2. `token = "gift_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)`; `code_hash = :crypto.hash(:sha256, token)`.
3. **Insert the gift** in a small `Ecto.Multi`/`Repo.transaction` (pure core → shell runs it): insert `Gift` (`:pending`, `code_hash`, `giver_user_id`, `pack_key`, `reviews` derived, `amount_cents = price`, `idempotency_key`, `expires_at = now + @gift_ttl_days`, `message`). **No `Credits.grant`** (escrow). The `gifts.idempotency_key` unique index is the row dedup; we write **no** `pricing_orders` row (that table is the buyer-grant flow gifting omits).
   - On the `idempotency_key` unique violation → **replay**: return `{:ok, :already_created}` (no token; the giver already has it via the email link — see Flow D). Do **not** re-charge.
4. **Charge in the shell, after commit:** `Billing.charge_gift(giver, pack_key, idempotency_key)` (the new charge-without-grant port). It records the Band-A `PricingAudit` and **threads `idempotency_key` to the provider** so a retried charge dedupes at the payment vendor (Stripe `Idempotency-Key`), not just at our row — closing the "charge before the row collides → double charge" gap. Stub = synchronous `{:ok, :charged}`.
   - **Charge failure:** surface the error; the just-inserted `:pending` gift carries no claimable value yet (no payment confirmed) — for Phase 1 (stub never fails) this is moot; for Phase 2 the gift is left `:pending` for the giver to retry/cancel, or swept. The token is **not** shown on a failed charge.
5. Post-commit (charge ok): emit `:"gift.purchased"`, telemetry `[:perfect_paper, :gifts, :purchased]`, deliver the giver's confirmation email (branded `Notifier`, gettext, **contains the claim link** — this email is the giver's durable system-of-record for the token; see Flow D).
6. Returns `{:ok, %{gift: gift, token: token}}` — plaintext shown on the success page **and** mailed in step 5. **Phase 2 (Stripe):** `charge_gift` returns a checkout reference; the gift stays `:pending` (or a `:pending_payment` sub-state) until the `checkout.session.completed` webhook confirms, then the confirmation email + token are sent. Deferred.

### B. Redeem — `Gifts.redeem(token, redeemer)`

1. `hash = :crypto.hash(:sha256, token)`.
2. `Repo.transaction`: `gift = Repo.one!(from g in Gift, where: g.code_hash == ^hash, lock: "FOR UPDATE")` (pessimistic). No row → `{:error, :not_found}` (generic; no enumeration).
3. Guard `status == :pending and expires_at > now` (the window is enforced here — a lagging-expired gift is rejected `{:error, :expired}` even before the cron sweeps it) else `{:error, :already_redeemed}` / `{:error, :expired}`.
4. Update `Gift` → `:redeemed`, `redeemer_user_id`, `redeemed_at`; then the **new dedup-capable grant** `Credits.grant(redeemer.id, reviews, "gift", :paid, metadata: %{source: "gift", gift_id: gift.id}, dedup: "gift_redeem:#{gift.id}")` (the prerequisite `Credits` extension — routes through `locked_insert`, so the `dedup` key is a second single-grant backstop beyond the `FOR UPDATE` guard).
5. **Lock order: gift row `FOR UPDATE` first, then the user advisory lock inside `grant`.** Non-gift user mutations only ever take the user advisory lock and never touch `gifts`, so this ordering is deadlock-free. A double-click / shared-link race → the second caller sees non-`:pending` → `{:error, :already_redeemed}`.
6. Self-redeem is **permitted** (harmless — the giver paid full Band-A price; no arbitrage, no special-case error logic).
7. Post-commit: emit `:"gift.redeemed"`, notify the **giver** ("your gift was claimed").

### C. Expiry — `GiftExpiryWorker` (Oban **unique** job, `:maintenance` queue, daily Cron)

- A **unique** Oban worker (`unique: [period: ...]`) so a re-enqueue can't overlap the next Cron tick and double-process (the `FOR UPDATE` re-check would still prevent a double grant, but uniqueness avoids the wasted connection contention).
- Select `:pending` gifts where `expires_at < now`, **`limit: 500`** per invocation (uses the partial index). If the batch fills to the limit, **re-enqueue via an explicit `Oban.insert`** (not in-process recursion); otherwise the next daily run sweeps the remainder. Bounds connection/pool usage on high-volume days.
- Per gift, in a `FOR UPDATE` transaction re-checking `status == :pending and expires_at < now` (idempotent):
  - `giver_user_id` present → `:expired` + `Credits.grant(giver_id, reviews, "gift_expired", :paid, metadata: %{source: "gift_expired", gift_id: id}, dedup: "gift_expired:#{id}")` (the dedup-capable grant),
  - `giver_user_id` nil → `:expired_forfeited`, **no grant**.
- Emit `:"gift.expired"` per processed gift; telemetry `[:perfect_paper, :gifts, :expired]` (batch size, grants, duration).

### D. Lost-token rescue & cancel (giver dashboard)

**Token durability model (one source of truth):** the **confirmation email (Flow A step 5) is the giver's system-of-record** for the claim link — the on-screen one-time display is a convenience, not the only copy. So the token is "shown once on screen" but **recoverable from the giver's mailbox**; the earlier "never recoverable" framing was wrong and is dropped. If the giver loses *both* the screen and the email, **Regenerate** is the rescue. On the giver's "sent gifts" dashboard, for any `:pending` gift:
- **Regenerate link (Phase 1):** generate a fresh token, update `code_hash` (under `FOR UPDATE`), show the new plaintext once (and re-mail it). Atomically voids the lost link (the old hash no longer matches) — no DB surgery, no support ticket.
- **Cancel / self-refund (Phase 2):** transition `:pending → :refunded`, disable the code, trigger the Stripe refund. Deferred with the rest of real-money handling.

**LiveView reconnect safety:** `GiftLive`'s connected `mount/3` reloads the sent-gifts list **from the DB** (`Gifts.list_sent(giver)`), never from stale socket assigns; a one-time token is **never re-rendered from assigns after a reconnect** (it lives in the email, per above). This honors the "don't restore from lost socket state" rule.

### E. Unauthenticated preview — `/gift/:token`

The landing page does a **read-only, lock-free** lookup (`Repo.get_by(Gift, code_hash: hash)`) to render "‹giver› sent you N review credits — log in to claim" (or a generic "this gift link is no longer valid" for non-`:pending`/missing). It acquires **no** `FOR UPDATE` lock — an anonymous visitor (or a crawler hitting URLs) can never trigger row locks. Only the authenticated **Claim** click invokes the transactional `Gifts.redeem/2`.

## Web surface

- `GiftLive` at `/gift` (under `:require_authenticated_user`): pick a pack (3/6/12) + optional message → buy → show the one-time claim link + a list of the giver's sent gifts with status and the Regenerate/Cancel actions. The sent-gifts list is rendered with **`phx-update="stream"`** (`stream_insert` on status flips / new gifts) so a status change doesn't re-send the whole list.
- `/gift/:token`: the preview/claim page (lock-free preview; authenticated Claim → `redeem/2`). A logged-out visitor is bounced through login/signup and returned to the claim.

## Events & telemetry

- **Registering the event types is part of THIS work:** add `:"gift.purchased"`, `:"gift.redeemed"`, `:"gift.expired"` to `Events.Event` `@types` (verified absent today — the allowlist ends at `invoice.paid`; an unregistered atom fails the `Ecto.Enum` cast and silently publishes nothing).
- Telemetry on every path, registered in `PerfectPaperWeb.Telemetry.metrics/0`: `[:perfect_paper, :gifts, :purchased]` (`amount_cents`, tag `pack_key`); `[:perfect_paper, :gifts, :redeemed]`; `[:perfect_paper, :gifts, :expired]` (batch size, grants, duration); and a **redeem-failure counter** tagged by reason (`:not_found` / `:already_redeemed` / `:expired`) so the new async/abuse surface is observable.
- Emails (branded `Notifier`, gettext-localized to the recipient's `user.locale`): giver purchase confirmation (with link), giver "gift claimed" notification.

## Error handling / edge cases

- **Deleted giver at expiry:** `nilify_all` FK → expiry job sees `giver_user_id == nil` → `:expired_forfeited`, no grant into the void. (Rare: platform-wide hard user deletion is out of scope today; this is defensive, matching `pricing_audits`.)
- **Double-redeem / shared-link race:** `FOR UPDATE` + `status == :pending` guard → exactly one grant; losers get `{:error, :already_redeemed}`. The ledger `dedup` key is a second backstop against a transaction retry double-granting.
- **Idempotent purchase:** unique `gifts.idempotency_key` dedupes the row; the charge dedupes at the provider via the same key threaded through `Billing.charge_gift` (so a retry can't double-charge). A replay returns `{:ok, :already_created}` (no token); the giver recovers the link from the confirmation email, or via Regenerate.
- **Expired code:** redeem guard rejects `expires_at <= now` with `{:error, :expired}` before any grant.
- **Unknown/forged code:** generic `{:error, :not_found}`; preview shows a neutral "no longer valid"; no enumeration of which codes exist.
- **Anonymous URL probing:** preview is lock-free and read-only; cannot starve the connection pool or lock rows.
- **Expiry batch overflow:** `limit: 500` + re-enqueue; never an unbounded sweep.
- **Self-redeem:** allowed; no exploit (full price paid).

## Testing

- **Prerequisites first.** `Credits.grant/5` (dedup-capable): granting twice with the same `dedup` key inserts one event (metadata carries `source`/`gift_id`); existing `grant/4` callers unaffected. `Billing.charge_gift/3`: records a Band-A `PricingAudit`, grants **nobody**, threads `idempotency_key` to the (stub) provider, and a retry on the same key charges once.
- **Purchase** (DataCase): creates a `:pending` gift, grants **nobody**, `amount_cents` is the Band-A price, `reviews` is **derived from `pack_key`** (a params map trying to set `reviews` directly is ignored / rejected); the charge runs after the insert; a second call on the same `idempotency_key` creates no second gift, does not re-charge, and returns no token.
- **Redeem** (DataCase): grants the recipient `reviews` once; a second redeem returns `{:error, :already_redeemed}` and grants nothing; a code whose `expires_at <= now` returns `{:error, :expired}` **even though the cron hasn't swept it** (window enforced at redeem); the credit event carries `metadata.gift_id`. Concurrency: two simultaneous `redeem/2` for one code → exactly one grant (FOR UPDATE).
- **Expiry** (DataCase, `Oban.Testing`): a `:pending` gift past `expires_at` → `:expired` + giver granted once; re-running the worker grants nothing more (idempotent); a gift with `giver_user_id: nil` → `:expired_forfeited`, no grant; the batch respects `limit`.
- **Regenerate** (DataCase): rotates `code_hash`, the old token no longer resolves, the new token redeems.
- **Hashing** (DataCase): the plaintext token never appears in the stored row; lookup by hash works.
- **Preview** (ConnCase/LiveView): `/gift/:token` renders the giver + count for a `:pending` gift, a neutral message otherwise, and takes no lock (no state change on visit).
- **Web** (LiveView): buying shows the one-time link; the sent-gifts list shows status; claim grants and flips status; gettext-localized (render a non-en locale).

## Dependencies / sequencing

- **Two API prerequisites land first** (their own tasks + tests, before the Gifts context): the dedup-capable `Credits.grant/5` and the charge-without-grant `Billing.charge_gift/3` (see Prerequisites). Both are verified-missing today.
- Reuses the **regional-pricing** pricing core (`Pricing.pack_price_for/2` for the Band-A amount, `PricingAudit` for the anti-arbitrage trail) — already on main. Row idempotency is the gift's own `idempotency_key` unique index (not `pricing_orders`); money idempotency is the same key threaded to the provider. Gift charges run on the **stub** (Phase 1), same as the rest of billing.
- Independent of the low-credit-alert feature.

## Out of scope (this pass — Phase 2 or separate spec)

Real Stripe gift charge + the `:refunded` pre-redemption-refund wiring (the state is designed in now; the webhook/refund integration lands with real-money handling) · org/group pool gifting · recipient-directed email delivery (we email only the giver) · gift bundles / custom credit amounts beyond the existing 3/6/12 packs · re-gifting a redeemed gift.
