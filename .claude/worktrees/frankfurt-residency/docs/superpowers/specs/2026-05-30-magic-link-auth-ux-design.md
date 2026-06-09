# Magic-link auth UX — design

**Date:** 2026-05-30
**Status:** Approved (brainstorming) — pending spec review
**Scope:** Polish the `register` and `log-in` LiveViews into a cohesive,
magic-link-first experience, matching the quality of the reference Credo app's
`user_live/*`, and add the supporting rate-limit + client-IP infrastructure.

## Problem

`/users/register` is the bare `phx.gen.auth` 1.8 scaffold: a lone email field
and a "Create an account" button, with no magic-link framing and a jarring
redirect-with-flash after submit. The magic-link *mechanism* already works
(`Accounts.register_user/1` → `Accounts.deliver_login_instructions/2`), but the
experience is unpolished. `/users/log-in` stacks two separate forms (magic link
and password) under an "or" divider rather than offering a clean toggle.

The reference Credo app (`/Users/bradhanks/Dev/credo/lib/credo_web/live/user_live/`)
demonstrates the target experience: magic-link-first forms, an in-place "Check
your email" confirmation state, a password toggle, and rate limiting with
anti-enumeration messaging. This spec brings that experience to Perfect Paper.

## Decisions (locked)

- **Scope:** Both the **register** and **login** pages.
- **Mode:** Magic-link-first. Login keeps a **"use a password instead"** toggle
  (password login already exists). Register is **magic-link only** — passwords
  are set later in Settings, matching the 1.8 scaffold (option A). No new
  registration-with-password changeset.
- **Confirmation:** In-place **"Check your email"** state (envelope icon,
  recipient address, rate-limited **Resend**), not a redirect-with-flash.
- **Security:** Add **Hammer** rate limiting (per-IP + per-email) and
  anti-enumeration copy.

## What already exists (do not rebuild)

- `Accounts.register_user/1` — email-only registration via `User.email_changeset`.
- `Accounts.get_user_by_email/1`, `Accounts.deliver_login_instructions/2`,
  `Accounts.get_user_by_magic_link_token/1`, `Accounts.login_user_by_magic_link/1`.
- Password login through `UserSessionController` + the password form in
  `UserLive.Login`.
- `UserLive.Confirmation` (the magic-link landing page) — unchanged.

## Architecture

Rate limiting and request metadata are **web-layer infrastructure** — no
business logic, no `Repo`, no vendor specifics — so they live under
`perfect_paper_web/`, not in a context. This respects the "contexts are the
only IO/business boundary" law: these modules do not touch domain data.

### New modules

```
lib/perfect_paper_web/rate_limit.ex          # Hammer wrapper
lib/perfect_paper_web/client_metadata.ex     # client IP from socket
```

**`PerfectPaperWeb.RateLimit`**

```elixir
@spec check(String.t(), pos_integer(), pos_integer()) :: :ok | :rate_limited
def check(key, window_ms, limit)
```

Wraps Hammer so callers never see Hammer's return shape (anti-corruption at the
web boundary). Backed by an ETS store supervised in `application.ex`.

**`PerfectPaperWeb.ClientMetadata`**

```elixir
@spec client_ip(Phoenix.LiveView.Socket.t()) :: String.t() | nil
def client_ip(socket)
```

Reads `x-forwarded-for` (first hop) from `:x_headers`, falling back to
`:peer_data` address, returning a printable string or `nil`. Returns `nil`
gracefully when `connect_info` is absent (e.g. the static render before the
socket connects), so callers use `client_ip(socket) || "unknown"`.

### Dependency + supervision

- Add `{:hammer, "~> 7.0"}` to `mix.exs`.
- Define `PerfectPaperWeb.RateLimit.Store` with `use Hammer, backend: :ets` and
  add it to the `application.ex` children so the ETS table is owned by the
  supervision tree. `RateLimit.check/3` delegates to the store's `hit/3`.

### Endpoint change

Add request metadata to the LiveView socket so rate-limit keys can include the
client IP:

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options, :peer_data, :x_headers]],
  longpoll: [connect_info: [session: @session_options, :peer_data, :x_headers]]
```

## Behaviour

### Rate-limit policy (shared by both pages)

| Key | Window | Limit |
|---|---|---|
| `auth_submit:ip:<ip>` | 60 s | 5 |
| `auth_submit:email:<downcased-email>` | 60 min | 5 |

- Per-IP cap throttles broad abuse from one source.
- Per-email cap blocks distributed-IP spam against one victim's inbox
  (uncapped per recipient lets an attacker flood any address with links).
- When throttled, respond with the **same success-looking** message and
  "Check your email" state as a real send (no signal that throttling occurred,
  and no signal whether the email exists).

### Register page (`UserLive.Registration`)

- **Form state:** email field, **"Send magic link"** primary CTA, anti-enumeration
  subtitle.
- **Submit ("save"):**
  1. Resolve client IP; check per-IP and per-email limits.
  2. If allowed: `register_user/1` for a new email (existing email simply
     returns a changeset error, which we swallow — see below), then
     `deliver_login_instructions/2`. Either way, transition to the check-email
     state.
  3. If throttled: transition to the check-email state with identical copy.
- **Anti-enumeration:** never reveal whether the email already exists. On a
  uniqueness error from `register_user/1`, look up the existing user and send
  them login instructions instead, then show the same check-email state. The
  changeset's `validate_unique: false` path is used for *live validation* only;
  format errors still surface inline before submit.
- **Check-email state:** envelope icon, "Check your email", "We sent a sign-in
  link to `<email>`", and a **Resend** action (re-runs the rate-limited send for
  the captured email). A secondary link returns to the form / points to login.
- **Copy:** "If an account exists for `<email>`, you'll receive a sign-in link
  shortly." Mentions that a password can be set later in Settings.

### Login page (`UserLive.Login`)

- **Single toggling form** replacing today's two-forms-with-divider layout:
  - **Magic-link mode (default):** email → **"Send magic link"**. Submit is
    rate-limited; existing users get `deliver_login_instructions/2`; the page
    transitions to the same **check-email** state with anti-enumeration copy.
  - **Password mode:** "Use a password instead" toggle reveals email + password
    + remember-me, posting to `UserSessionController` exactly as today
    (`phx-trigger-action`). Unchanged auth path.
- The local-mail-adapter info alert is preserved.

### Shared UI

- Both pages render the same magic-link form + `check_email` panel markup,
  styled with daisyUI **semantic** classes and the `.ds-*` type helpers on the
  `paper` theme. Sentence case, no emoji, "PerfectPaper" one word.
- Auth LiveViews keep **inline `~H` render/1** (the existing scaffold style —
  these are not collocated-template LiveViews).

## Error handling

- `ClientMetadata.client_ip/1` returns `nil` when metadata is unavailable;
  callers fall back to `"unknown"` so rate limiting still functions (all
  unknown-IP traffic shares one bucket).
- `deliver_login_instructions/2` failures are swallowed (best-effort email);
  the user still sees the check-email state (no enumeration signal).
- `register_user/1` uniqueness errors are handled per the anti-enumeration flow
  above; genuine format errors re-render the form with inline errors.

## Testing (TDD — red → green → refactor)

- **`PerfectPaperWeb.RateLimit`** (unit): allows calls under the limit; returns
  `:rate_limited` once the limit is exceeded within the window; independent keys
  are independent.
- **`UserLive.Registration`** (LiveView):
  - submitting a new email delivers login instructions and shows the
    check-email state;
  - submitting an existing email shows the *same* check-email state (no
    enumeration) and delivers instructions to the existing user;
  - exceeding the rate limit shows the check-email state without an extra send;
  - invalid email format shows an inline error and no send.
- **`UserLive.Login`** (LiveView):
  - the "use a password instead" toggle reveals the password form;
  - the magic-link submit for an existing user delivers instructions and shows
    check-email;
  - the magic-link submit for an unknown email shows the same state (no send,
    no enumeration).

Run only these targeted tests during development; reserve `mix precommit` for
the pre-merge check.

## Out of scope

- Password-at-registration (option B) — passwords are set in Settings.
- Changes to `UserLive.Confirmation`, `UserSessionController`, or the
  `Accounts` context API.
- Captcha, email-domain blocklists, lead capture, or analytics (Credo-specific
  features not part of Perfect Paper).
