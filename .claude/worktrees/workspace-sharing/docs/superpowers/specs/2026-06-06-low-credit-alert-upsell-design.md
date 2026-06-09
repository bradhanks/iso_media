# Design: Low-Credit Alert & Upsell

**Date:** 2026-06-06
**Status:** Draft for review
**Context:** Credits are an append-only ledger (`PerfectPaper.Credits`); balance is derived. A low-balance nudge already exists (`Credits.notify_low_balance/1`) sending an email via the Resend mailer. The Events bus + Oban are available. There is no user-configurable threshold and no in-app low-credit affordance today.

## Summary

When a writer's remaining review credits drop to/below a per-user threshold, alert them **in-app** and by **email**, with an upsell to the 12-pack (17% off). Annual subscribers are the priority audience (default threshold 5). The email fires **once per crossing** (not on every charge); the in-app banner shows while the balance is low.

## Decisions (locked during brainstorming)

- **Trigger = remaining balance ≤ threshold** (not a usage-rate metric).
- **Per-user threshold**, set in account settings. **Defaults: annual subscribers = 5, everyone else = 1.**
- **In-app + email.**
- **Email fires once per threshold crossing**, with a cooldown: re-arm only after the balance recovers **above** the threshold (no repeat spam while low).
- **Upsell target = the 12-pack (`:pack_12`, 17% off)**; annual subscribers get a "top up to finish your year" copy variant. (A bespoke annual-only incremental deal is a future enhancement — not this pass.)
- Reuse `Credits.notify_low_balance/1`, the Events bus, Oban, the Resend mailer — don't reinvent.

## Architecture

### Data — the threshold setting
- Add `field :low_credit_threshold, :integer` to `Accounts.User` (nullable). `nil` means "use the plan default."
- **Effective threshold** is a pure function: `effective_low_credit_threshold(user, subscription)` → `cond: user.low_credit_threshold != nil -> that (0 disables, see edge cases); annual?(subscription) -> 5; true -> 1`. One rule, one place.
  - **`annual?` = the user's PERSONAL `Billing.Subscription.interval == :year`** — the field the regional-pricing spec adds. **Not** `Billing.Contract.interval` (`:annual`): that is the *enterprise org seat contract* (Spec 4), a different concept; conflating them would mis-default org members. Personal-annual subscriptions **do not exist until the regional-pricing spec ships `Subscription.interval`** — so if this feature lands first, `annual?` is always false and everyone defaults to 1 (see Dependencies).
- Migration: additive nullable column (safe, std 4); no backfill.

### Trigger — crossing detection (no latch, no per-charge spam)
The alert fires on the **transition** from above-threshold to ≤threshold, exactly once, and re-arms automatically. **No `User` cooldown column** (the first-draft latch was wrong: it lives outside the ledger's `pg_advisory_xact_lock`, and `grant/4` takes no lock — so set/clear would race). Instead the crossing is computed **inside the existing per-user advisory lock** from before/after balance:
- `Credits.charge_*` already wraps its ledger write in a `lock_user` (`pg_advisory_xact_lock(hashtext(user_id))`) transaction. Within that locked transaction, compute `balance_before` and `balance_after`; the charge **crossed low** iff `balance_before > threshold and balance_after <= threshold`. This is atomic with the balance change — no separate latch, no grant-path bookkeeping, and it re-arms for free (a later top-up makes `balance_before > threshold` true again before the next crossing). Subsequent charges while already below have `balance_before <= threshold` → no re-fire.
- **Emit POST-COMMIT, from the transaction owner, not from inside the savepoint.** The production charge runs inside `History.process_session`'s outer `Multi` (`charge_for_level` → `Credits.charge_*` nests as a savepoint), so `Credits` **cannot** know the outer transaction committed. `Credits.charge_*` therefore **returns** the `crossed_low?` boolean (alongside `{:ok, balance}`); `History.process_session` emits `:"credits.low"` **after `Repo.transaction` returns `{:ok, …}`** (`events.ex` rule: never before commit). This also fixes the pre-existing smell where `Credits.maybe_emit_low_balance` emits from inside the savepoint today — that emit moves to the post-commit site. Direct callers (e.g. tests, any future non-History charge) get the flag and emit at their own post-commit boundary.
- `threshold` is `effective_low_credit_threshold(user)` read once inside the locked op.

### Event — REUSE the existing one, don't invent
`:"credits.low"` is **already a registered `Events` type** and is already emitted (`credits.ex`), but **has no subscriber**. Do NOT invent `:"credit_balance.low"` (an unregistered atom fails `Event`'s `Ecto.Enum` cast → `emit` returns `{:error, changeset}` and silently publishes nothing). Instead: extend the existing `:"credits.low"` payload with `%{user_id, balance, threshold, annual?}`, move its emit to the post-commit site (above), and **add the missing subscriber**.

### Notification — email (event-driven, once) + in-app (stateless, while low)
- **Email:** an `Events` subscriber enqueues an Oban job on a **new `:notifications` queue** (added to `config :perfect_paper, Oban` — current queues `webhooks/documents/reviews/teams_notifier` don't fit user-facing email). The job calls a **new** `Credits.deliver_low_balance_upsell(user, balance, threshold)` (the current `notify_low_balance/1` + `Notifier.deliver_low_balance/3` are hardcoded English and don't take a CTA — this is a real signature change, not a no-op reuse). It must: **localize via the recipient's `user.locale`** (set `Gettext.put_locale` + `gettext`/`ngettext` for "N credits"), include the upsell CTA, and branch copy annual vs. not. **Dedup:** the post-commit emit already fires once per crossing; the Oban job is `unique` keyed on the emit's identity so a *retry* can't double-send. Prefer keying on a **monotonic crossing/event id** (carried in the event payload) over an hour-truncated timestamp — hour-bucketing would collapse two genuine crossings in the same hour (burn below → top up → burn below) into one email, which contradicts "a genuine later crossing still sends." If a coarse window is acceptable as a deliberate anti-nag throttle, state that explicitly; otherwise key on the event id.
- **In-app:** a **pure function component** banner in `AppShell` rendered whenever the current scope's personal balance ≤ effective threshold — *stateless*, derived from balance, so it appears while low and vanishes once topped up (no event, reconnect-safe). Dismissible per session (cookie, like cookie-consent). CTA → the largest-pack checkout; annual copy variant. Localized via gettext (`ngettext` for the count), reduced-motion, sentence case, no emoji.
  - **Only for personal (user-owned) context.** A writer acting in a **group/org** scope draws the **org pool**, not personal credits (`History.charge_for_level(%{owner_type: :group})` → `Organizations.charge_pool`), so the "your balance" banner must NOT show for group-context activity — guard on personal ownership.
  - Balance + threshold are added as **socket assigns** (not onto `Scope`, which carries only `user`/`group_paths`): compute once in the authenticated `on_mount` (`mount_current_scope`) so each authed page renders the banner without refetching. `balance/1` is a single indexed `SUM` over `credit_events` (`[:user_id]` index exists), so it's one aggregate per mount, no N+1. **Scale watch-item:** this adds a `SUM` to *every* authenticated mount (and mount runs twice per navigation: disconnected + connected = 2 aggregates), growing O(events-per-user). Fine for MVP; if per-user `credit_events` grows large, move to a materialized/cached balance — flag, don't pre-optimize. Nil-guard the first render before the assign is set.

### Settings UI
- `UserLive.Settings` gains a "Credit alerts" section: a number input for `low_credit_threshold` (blank = plan default, shown as a hint "Default for your plan: N"), submitting through a new `Accounts.update_low_credit_threshold/2`. Mirrors the locale section added earlier. Validate `>= 0` and a sane max.

## Events & telemetry

- The event is the **already-registered `:"credits.low"`** (post-commit emit) — fans out to in-process PubSub (a LiveView could react live) and the email Oban subscriber. **Do not** introduce `:"credit_balance.low"` anywhere — it's not in `Event`'s `@types`, so `emit` would return `{:error, changeset}` and silently publish nothing.
- `:telemetry.execute([:perfect_paper, :credits, :low_balance_alert], %{balance, threshold}, %{annual?: boolean})` on emit, so the alert/upsell funnel is measurable.

## Error handling / edge cases

- **Threshold 0 = disabled (explicit branch):** since the trigger is `balance <= threshold` and balance legitimately reaches 0, `0 <= 0` would *fire*, not disable. So `0` must be an **explicit short-circuit** — `effective_low_credit_threshold` returning `0` (or the trigger) means "no alert," handled by a guard (`threshold > 0 and crossed?`), not as an emergent property. Also bound the user-settable max (e.g. ≤ the largest pack size) so the in-app banner can't be made permanently-on.
- **Already below at signup:** a brand-new annual user granted 12 starts above 5 → no alert; correct.
- **No latch — there is no `low_credit_alerted_at` column.** The crossing is the *stateless* `balance_before > threshold and balance_after <= threshold` computed inside the existing per-user advisory lock (see Trigger); it re-arms automatically (a later top-up makes `balance_before > threshold` true before the next crossing). Earlier drafts proposed a `User` latch — it was deliberately removed (it lived outside the ledger lock and `grant/4` takes no lock).
- **Recovery race:** because the crossing is computed atomically within the lock from before/after balance, interleaved grant/charge can't produce a lost wakeup or double-fire — each charge sees a consistent before/after under the lock.
- **Roll-back safety:** the `crossed_low?` flag is only **acted on (emitted) in the `{:ok, _}` branch** after the outer `process_session` transaction commits; if the transaction rolls back, the flag is discarded and no alert fires for a charge that didn't happen.
- **Guest/invited users without email:** skip the email (no address); the in-app banner still applies once they have a session.
- **Email send failure:** Oban retries (the job is idempotent via its unique key — see below); a transient failure is covered by retries and does not suppress a future genuine crossing (which is a new emit, not gated by any persisted latch).

## Testing

- **`Credits` threshold + crossing** (DataCase, async): charging across the threshold returns `crossed_low? == true` once; further charges while already below return `false` (no re-emit); a top-up above threshold then a re-cross returns `true` again (stateless re-arm); `threshold == 0` never crosses. No latch column is read/written.
- **Post-commit emit** (DataCase): a `process_session` whose transaction commits emits `:"credits.low"` once; a `process_session` that rolls back (e.g. forced comment-insert failure) emits **nothing** even though the inner charge computed a crossing.
- **`effective_low_credit_threshold`** (pure, async): annual (personal `Subscription.interval == :year`) → 5; non-annual → 1; explicit user value overrides; `0` → disabled; no annual subscription / interval field absent → non-annual.
- **Email** (DataCase): the Oban job calls `Credits.deliver_low_balance_upsell` with upsell CTA + annual/non-annual copy, **localized to `user.locale`**; the Oban unique key prevents double-send on retry; no email when no address.
- **In-app banner** (ConnCase/LiveView): renders when balance ≤ threshold, hidden otherwise, dismiss works, CTA points at the 12-pack; gettext-localized (render a non-en locale).
- **Settings** (LiveView): saving a threshold persists it; blank → plan default; validation rejects negatives.

## Dependencies / sequencing

- **Build AFTER regional-pricing Phase 1.** This feature's two anchors come from that spec: personal-annual subscriptions (`Subscription.interval == :year`, which gives the `annual? → 5` default *any* meaning) and `:pack_12` (the 17% upsell target). Built before it: `annual?` is always false (default 1 for all), and the CTA points at today's largest pack (`:pack_10`, no banded/17% price). So sequence it second.
- **Upsell price must come from the pricing API, not a literal.** When regional pricing ships, the email/banner CTA shows the **band-adjusted** `:pack_12` price for the recipient (a Band-C user sees the banded number, not `$499.99`) by calling `Billing.Pricing.pack_price_for(:pack_12, band)` — never an embedded constant.

## Out of scope

Usage-rate ("N used per period") alerts · the bespoke annual-only incremental-pack deal (future) · SMS/push · dunning for failed payments.
