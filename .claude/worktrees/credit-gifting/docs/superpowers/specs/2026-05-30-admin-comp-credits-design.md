# Admin "comp credits" page — design

**Date:** 2026-05-30
**Status:** Approved, pre-implementation

## Goal

A dead-simple, operator-only page to grant goodwill ("comp") credits to an
account when something breaks or a user is unhappy with results. Builds directly
on the existing append-only credits ledger — a comp is just a positive
`credit_event`. No new table, no role column.

## Background

The `Credits` context (`lib/perfect_paper/credits.ex`) already tracks credits as
an append-only `credit_events` ledger: positive `amount` = grant, negative =
charge, balance is the sum. It exposes `grant/3`, `balance/1`, and
`charge_for_proofreading/1`. `CreditEvent` carries a free-form `reason` (required)
and a `metadata` map (default `%{}`). `Accounts.get_user_by_email/1` exists.

What is missing is a **human-friendly, attributed** way for an operator to issue a
grant by email without dropping into raw Ecto/IEx.

## Components

### 1. Credits context — attributed comp grant

New business-readable function alongside `grant/3`:

```elixir
@spec comp_account(Ecto.UUID.t(), pos_integer(), String.t(), Ecto.UUID.t()) ::
        {:ok, CreditEvent.t()} | {:error, Ecto.Changeset.t()}
def comp_account(user_id, amount, reason, granted_by_id)
    when is_integer(amount) and amount > 0
```

- Inserts a positive `CreditEvent` with the human `reason` (e.g. "sorry for the
  outage") and stashes audit attribution in the existing `metadata` map:
  `%{"kind" => "comp", "granted_by" => granted_by_id}`.
- Validated through `CreditEvent.create_changeset/2` (architecture law #4). Reuses
  the schema as-is — **no migration**.
- `grant/3` stays as the generic primitive; `comp_account/4` is the comp-specific,
  attributed entry point.

### 2. Admin gate — config email allowlist

No admin/role concept exists today, and we are not adding one.

- `config :perfect_paper, :admin_emails, [...]` — env-driven in prod
  (`config/runtime.exs`), explicit list in dev/test config.
- New `on_mount` hook `PerfectPaperWeb.UserAuth.require_admin/4`: reads the
  configured allowlist, compares against the logged-in user's email; if not an
  admin, halts the mount with a flash and redirect to `/`.
- A small helper resolves the allowlist from config so it is testable.

### 3. `AdminLive.Credits` LiveView at `/admin/credits`

Collocated template: `lib/perfect_paper_web/live/admin_live/credits.ex` +
`credits.html.heex`. daisyUI **semantic** classes per BRAND.md (no raw Tailwind
colors), sentence case, no emoji.

Behaviour:

- **Lookup:** operator types an email and submits → `Accounts.get_user_by_email/1`.
  - Found → assign the user; show their current `Credits.balance/1`.
  - Unknown email → inline "no account found" message (no crash, no flash spam).
- **Grant:** once a user is loaded, an amount + reason form is shown.
  - Form is backed by a **schemaless `Ecto.Changeset`** (`amount` integer > 0,
    `reason` required, trimmed) so validation happens before touching the context
    (law #4).
  - Submit → `Credits.comp_account(user.id, amount, reason, current_user.id)`.
  - On success → success flash, reset the grant form, and refresh the displayed
    balance in place.
  - On error → surface changeset errors on the form.

### 4. Router

Add a new authenticated admin `live_session`:

```elixir
scope "/admin", PerfectPaperWeb do
  pipe_through [:browser, :require_authenticated_user]

  live_session :require_admin,
    on_mount: [
      {PerfectPaperWeb.UserAuth, :require_authenticated},
      {PerfectPaperWeb.UserAuth, :require_admin}
    ] do
    live "/credits", AdminLive.Credits, :index
  end
end
```

## Data flow

```
operator enters email
  → Accounts.get_user_by_email/1
  → Credits.balance/1            (display)
  → submit grant form
  → Credits.comp_account/4       (positive CreditEvent + metadata attribution)
  → success flash + Credits.balance/1 refresh
```

## Error handling

- Unknown email → inline "no account found", form for grant not shown.
- Invalid amount (≤ 0, non-integer) or blank reason → schemaless changeset errors
  on the form; context never called.
- Non-admin user reaching `/admin/credits` → `require_admin` on_mount redirects to
  `/` with a flash. Unauthenticated user → existing `require_authenticated_user`
  pipeline/`on_mount` redirects to log-in.

## Testing (TDD: red → green → refactor)

**Credits context** (`test/perfect_paper/credits_test.exs`):
- `comp_account/4` inserts a positive event, sets `reason`, records
  `%{"kind" => "comp", "granted_by" => admin_id}` in metadata, and `balance/1`
  increases by `amount`.
- rejects non-positive amount (guard) / blank reason (changeset error).

**LiveView** (`test/perfect_paper_web/live/admin_live/credits_test.exs`):
- non-admin authenticated user is redirected away from `/admin/credits`.
- admin can load the page, look up an existing user, and see their balance.
- admin grant updates the displayed balance and shows a success flash.
- unknown email shows the "no account found" message.

## Out of scope (YAGNI)

- Recent-grants / audit-log table view (attribution is captured in metadata for a
  future view).
- `is_admin` column or `role` enum on users.
- Admin REST endpoint.
- Revoke/clawback (ledger is append-only; a correction would be its own feature).
