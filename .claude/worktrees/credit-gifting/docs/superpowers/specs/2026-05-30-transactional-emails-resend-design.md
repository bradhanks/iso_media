# Transactional Emails + Resend Integration — Design

**Date:** 2026-05-30
**Branch:** `feature/transactional-emails-resend`
**Status:** Approved (design), pending implementation

## Goal

Give PerfectPaper a complete, branded transactional-email layer for a standard
SaaS — auth, billing, credits, organizations, referrals, documents — delivered
through **Resend** in production. Emails should feel polished and warm (Canva /
PhotoDay energy) while staying measured and scholarly per `BRAND.md`. The
referral emails and the "free credit" email are the showcase activation pieces.

## Constraints & decisions

- **Delivery via Swoosh's built-in Resend adapter** (`Swoosh.Adapters.Resend`,
  already vendored in `deps/`). Keep `PerfectPaper.Mailer`. No new dependency,
  no vendor leak past the Swoosh adapter, fully testable with
  `Swoosh.Adapters.Test`. The pasted `resend` hex SDK is **not** used.
- **Secrets via env only.** `RESEND_API_KEY` read in `config/runtime.exs`. The
  key shared in chat must be **rotated** — it is considered compromised. Never
  committed.
- **From address:** `no-reply@perfectpaper.org` with display name `PerfectPaper`,
  env-overridable via `MAIL_FROM`. Live sends require `perfectpaper.org` DNS
  verified in Resend (documented below; does not block dev/test).
- **Email header:** CSS wordmark + bulletproof table buttons. No external
  images, so nothing to be blocked. Brand colors inlined as hex (daisyUI CSS is
  unavailable in mail clients). Fraunces/Newsreader offered as progressive
  enhancement with web-safe fallbacks.
- **Architecture laws** (CLAUDE.md) hold: each context owns its own notifier and
  exposes business-readable public functions; the web layer / other contexts
  call the context API, never a notifier submodule. `PerfectPaper.Email` is a
  shared leaf (same category as `Mailer`, `Types`, the mailer — explicitly
  allowed by Architecture Law 3).
- **Out of scope this pass:** background jobs / drip scheduling. The "free
  credit" email is wired so it fires whenever a free credit is granted; the
  weekly auto-drip that *calls* the grant is a later job and is **not** built
  here. Stated plainly so we don't imply automation that doesn't exist.

## Architecture

```
lib/perfect_paper/mailer.ex                 # exists — Swoosh.Mailer (unchanged)
lib/perfect_paper/email.ex                  # NEW shared leaf: from-config, render, deliver helper
lib/perfect_paper/email/layout.ex           # NEW: branded HEEx layout + shared components
lib/perfect_paper/accounts/user_notifier.ex # UPGRADE: plaintext → branded HTML + welcome
lib/perfect_paper/billing/notifier.ex       # NEW
lib/perfect_paper/credits/notifier.ex       # NEW
lib/perfect_paper/organizations/notifier.ex # NEW
lib/perfect_paper/referrals/notifier.ex     # NEW
lib/perfect_paper/documents/notifier.ex     # NEW
```

### `PerfectPaper.Email` (shared leaf)

The single rendering + delivery helper every notifier uses. It does **not** do
business logic and is not a context.

```elixir
@spec deliver(to :: String.t(), subject :: String.t(), Phoenix.HTML.safe()) ::
        {:ok, Swoosh.Email.t()} | {:error, term()}
```

Responsibilities:
- Read `from_name` / `from_email` from `config :perfect_paper, :mail`.
- Take a rendered HEEx body (the inner content), wrap it in the branded layout
  (`Email.Layout.document/1`), produce an **HTML body** and an auto-derived
  **plaintext fallback** (strip tags / use a provided text alt), build the
  `Swoosh.Email`, and call `Mailer.deliver/1`.
- Return `{:ok, email} | {:error, reason}` — never raise on delivery failure.

A small `Email.Layout` module holds `Phoenix.Component` function components:
`document/1` (outer table shell + Mulberry→Teal header band + Gold accents +
footer), `button/1` (bulletproof table button, Mulberry fill), `panel/1`
(hairline-bordered card), `eyebrow/1`, `muted_footer/1`. All styles inline.

### Per-context notifiers

Each notifier is a thin module that builds the inner HEEx for its emails and
calls `Email.deliver/3`. Each **context module** exposes the business-readable
public functions; the notifier is a private collaborator within the context.

## Email catalog

| # | Email | Context fn (public API) | Wiring this pass |
|---|---|---|---|
| 1 | Account confirmation | `Accounts.deliver_login_instructions` (existing, unconfirmed branch) | upgrade to HTML |
| 2 | Magic-link login | `Accounts.deliver_login_instructions` (existing, confirmed branch) | upgrade to HTML |
| 3 | Email-change instructions | `Accounts.deliver_user_update_email_instructions` (existing) | upgrade to HTML |
| 4 | Welcome | `Accounts` — fired on first confirmation in `login_user_by_magic_link` | wired |
| 5 | Free credit granted (activation) | `Credits.grant/3` → `Credits.Notifier` (showcase) | wired into `grant/3` |
| 6 | Credits running low | `Credits.notify_low_balance/1` | public fn + test |
| 7 | Subscription confirmed | `Billing.send_subscription_confirmation/1` | public fn + test |
| 8 | Payment receipt | `Billing.send_payment_receipt/2` | public fn + test |
| 9 | Payment failed (dunning) | `Billing.send_payment_failed/1` | public fn + test |
| 10 | Subscription canceled | `Billing.send_subscription_canceled/1` | public fn + test |
| 11 | Team invitation | `Organizations.send_invitation/3` | public fn + test |
| 12 | Referral invitation (to friend) — showcase | `Referrals.send_referral_invitation/3` | public fn + test |
| 13 | Referral reward earned (to referrer) — showcase | `Referrals.notify_reward_earned/2` | public fn + test |
| 14 | Document proofreading complete | `Documents.notify_proofreading_complete/2` | public fn + test |

Notes:
- Functions that take recipient/amount/url as plain args (not derivable from a
  schema in this stubbed pass) keep simple, explicit signatures and are tested
  directly via `Swoosh.TestAssertions`. No fake business logic is invented to
  manufacture a call site.
- #5 free-credit email: `Credits.grant/3` already records the grant. After a
  successful insert, fire the notifier. To keep the email "free credit"
  specific, it sends only when the grant `reason` marks it a free/bonus credit
  (e.g. `reason` in `~w(signup_bonus weekly_free_credit referral_bonus)`), and
  requires the user's email — `grant/3` gains an optional `notify: %{email: ...}`
  so the ledger function stays usable without a user struct. Sending failure is
  logged, never breaks the grant.

## Brand / rendering details

- Header: full-width band, left-to-right Mulberry `#7a2e4e` → Teal `#1f5e58`
  gradient (with solid Mulberry fallback for clients that drop gradients), large
  `PerfectPaper` wordmark in white, Gold `#c28a3a` hairline accent rule.
- Body on Paper cream `#fbf8f2`, Ink `#211c18` text, 1px hairline borders, low
  radius — editorial, flat (no shadows), matching the `paper` theme.
- Buttons: bulletproof `<table>` button, Mulberry fill, white text, ~6px radius.
- Footer: muted, includes PerfectPaper wordmark, a one-line tagline, and
  (where relevant) an unsubscribe/manage-preferences line pointing at the
  Marketing context's preferences (link only; no new flow built).
- Sentence case, no emoji in product copy, always "PerfectPaper" (one word).
- Showcase emails (#5, #12, #13) get warmer, more celebratory copy and a Gold
  accent flourish while staying on-brand.

## Config changes

```elixir
# config/config.exs
config :perfect_paper, :mail,
  from_name: "PerfectPaper",
  from_email: "no-reply@perfectpaper.org"
config :perfect_paper, PerfectPaper.Mailer, adapter: Swoosh.Adapters.Local  # unchanged

# config/test.exs — unchanged (Swoosh.Adapters.Test)

# config/runtime.exs (inside if config_env() == :prod)
config :perfect_paper, PerfectPaper.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: System.get_env("RESEND_API_KEY")

config :perfect_paper, :mail,
  from_name: "PerfectPaper",
  from_email: System.get_env("MAIL_FROM") || "no-reply@perfectpaper.org"
```

`config :swoosh, api_client: Swoosh.ApiClient.Req` already set in `prod.exs`.

### DNS / Resend setup (operational, documented not coded)

1. Add `perfectpaper.org` as a domain in Resend.
2. Add the SPF, DKIM, and DMARC DNS records Resend provides; wait for verified.
3. Set `RESEND_API_KEY` (rotated key) and optionally `MAIL_FROM` in prod env.
4. Until verified, prod sends will be rejected by Resend; dev/test unaffected.

## Error handling

- `Email.deliver/3` returns `{:ok, _} | {:error, _}`; never raises on transport.
- Notifier calls placed **outside** any `Ecto.Multi` / transaction. On
  `{:error, _}` the caller logs (`Logger.warning`) and continues — a failed
  email never rolls back a billing/credit/document state change.

## Testing (TDD, red → green → refactor)

- `test/perfect_paper/email_test.exs` — layout renders, from-address from
  config, plaintext fallback present, HTML contains wordmark.
- Per-context notifier tests using `Swoosh.TestAssertions.assert_email_sent`,
  asserting recipient, subject, and that the HTML body contains the key action
  URL / amount / brand copy for each email.
- Upgrade existing `accounts` auth-email tests to assert HTML body + URL still
  present (magic-link, confirmation, email-change), plus new welcome + free
  credit behavior.
- Run only touched tests during development; full `mix precommit` before merge.

## Out of scope (restated)

Background jobs / weekly drip scheduling · webhooks · real payment vendor ·
unsubscribe flow implementation (link only) · GraphQL · realtime. The drip that
auto-grants 3 credits in week one is a future job; only the email it would
trigger is built now.
