# CLAUDE.md — Perfect Paper

Authoritative guide for working in this repo. Read before writing code.
Full design: `docs/superpowers/specs/2026-05-30-perfect-paper-mvp-design.md`.

## What this is

Perfect Paper is **Refine.ink** (React + Python/FastAPI + Clerk) refactored into
a **Phoenix LiveView / Elixir** app. A document-proofreading product: users
upload documents, get AI feedback as comments, and act on them (dismiss /
address / undo), with credits, subscriptions, organizations, and an API-key
surface.

**Nothing from the React/TypeScript/Clerk/FastAPI stack comes over.** Bring over
business logic, tables/changesets, and the two read surfaces only.

## Stack

- Elixir / Phoenix **1.8**, LiveView, Bandit
- PostgreSQL via Ecto, **`binary_id`** primary keys, enums as strings (`Ecto.Enum`)
- Auth: local `phx.gen.auth` (`user_auth.ex`) — **no Clerk**
- Styling: Phoenix 1.8 native **Tailwind v4 + daisyUI**; build components with the
  **daisyUI-blueprint MCP** (`daisyUI-Snippets`, `Figma-to-daisyUI`)
- APIs this pass: **REST + LiveView only** (no GraphQL yet)

## Brand & UI

PerfectPaper is an **AI peer reviewer for academic papers** — voice is measured,
warm, scholarly. Full brand in `/BRAND.md`; design kit + mockups in `docs/design/`.

- **Theme:** the `paper` daisyUI theme (default) is defined in `assets/css/app.css`
  — **Mulberry** `#7a2e4e` (primary), **Teal** `#1f5e58` (secondary), **Gold**
  `#c28a3a` (accent — **fills/icons only; fails as text on cream**), on warm Paper
  cream `#fbf8f2` with Ink `#211c18` text. Variants `paper-dark`, `paper-navy`.
  Editorial feel: low radius, hairline 1px borders, flat (`--depth: 0`).
- **Type — "serif to read, sans to operate":** `font-display` = Fraunces
  (headlines), `font-serif` = Newsreader (long-form reading), `font-sans` = Outfit
  (UI). Self-hosted variable `.ttf` from `priv/static/fonts`. Helpers: `.ds-h1/2/3`,
  `.ds-lead`, `.ds-p`, `.ds-eyebrow`.
- Use daisyUI **semantic** classes (`btn-primary`, `bg-base-200`) — never raw
  Tailwind colors (`bg-gray-800`) for themeable surfaces. Build components with the
  **daisyUI-blueprint MCP** + the mockups in `docs/design/mockups/`.
- No emoji in product UI. Sentence case. Always "PerfectPaper" (one word) in copy.

## The one idea: functional core, imperative shell

Data and validation are **pure**; queries support the business logic they serve.
The context module is the **only** place that does IO (`Repo`, external calls)
and the **only** entry point other contexts or the web layer may call.

```
lib/perfect_paper/<context>.ex            # PUBLIC API + sole Repo/IO boundary + most queries
lib/perfect_paper/<context>/<schema>.ex   # Ecto schema + its changeset(s), together

# Break a piece out into its own module ONLY when it gets large/involved:
lib/perfect_paper/<context>/<schema>/changeset.ex  # optional: big changeset logic
lib/perfect_paper/<context>/<schema>/query.ex      # rare: large standalone query module
```

Default to the flat layout, and **write queries inline** in the context function
that uses them — most are a `Repo.get`/`Repo.get_by` or a small `from(...)`.
Promote a query to a **named builder only to kill duplication**: when the same
filter/scope repeats across functions (`for_user`, `visible_to`, `not_deleted`),
extract it — usually as a private function in `<context>.ex`. A collection of
query functions for its own sake is an anti-pattern. A standalone `query.ex`
module is rarer still — only when those reused builders grow large/complex.

## Architecture laws (do not violate)

1. **One context = the only public API and the only `Repo`/IO boundary.** Web
   layer and other contexts call `PerfectPaper.<Context>` functions — never a
   submodule, never `Repo` directly.
2. **Schemas carry their own changesets.** `<context>/<schema>.ex` holds the
   schema (fields + `@type`) **and** its changeset function(s); changesets are
   pure (`Ecto.Changeset`, no `Repo`). **Queries are written inline** in the context
   function that uses them; promote a scope to a named builder (a private fn in
   the context) only when it actually repeats across functions. Split a
   `changeset.ex`/`query.ex` module out **only** when that logic gets large.
3. **Contexts are the boundary, not submodules.** Treat each context as
   standalone as far as practical; **cross-context** access goes through context
   APIs only (shared leaves like `PerfectPaper.Types` and the mailer excepted).
   **Within** a context, submodules may call siblings freely — just prefer not to
   reach deep into another submodule's internals, and keep related code in its
   own subfolder where natural. Not a hard rule.
4. **Changeset on every write — even when it doesn't persist.** Validate inbound
   params and adapter results through `Ecto.Changeset` (schemaless or
   `embedded_schema`). **The DB layer holds no business logic.**
5. **Typespecs always.** `@spec` on every public function; `@type` on structs;
   `@moduledoc`/`@doc` on public modules/functions.
6. **Business-readable names.** A context function reads as the step a human in
   that role would take: `History.dismiss_comment(session_id, comment_id, by: user_id)`,
   `Credits.charge_for_proofreading(user)`, `Billing.upgrade_plan(...)`. A VP of
   Sales should be able to read the context API.
7. **Side-effects sit behind a behaviour + config-selected adapter** (an
   anti-corruption layer). No vendor JSON keys, error codes, or API shapes leak
   past the adapter. Adapters return **atom-keyed maps matching Ecto schema
   fields** so the context passes them straight into changesets.
8. **Multi-step writes use `Ecto.Multi`** inside the context.

### Vendor / side-effect adapters

| Concern | Behaviour | Default adapter | Config key |
|---|---|---|---|
| Payments | `Billing.Provider` | `Billing.StubAdapter` | `:billing_provider` |
| Language model | `Chatbot.LLM` | `Chatbot.LLM.Stub` | `:llm_provider` |
| Blob storage | `Documents.Storage` | `Documents.Storage.Local` | `:storage_provider` |
| Outbound webhooks | `Webhooks.Sender` | `Webhooks.Sender.Req` | `:webhook_sender` |

The behaviour defines `@callback`s with full typespecs; the adapter is the only
module that references vendor specifics or performs the external call. Select via
`config :perfect_paper, :billing_provider, PerfectPaper.Billing.StubAdapter`.

## Contexts

`Accounts`, `ApiKeys`, `History`, `Credits`, `Chatbot`, `Documents`, `Billing`,
`Organizations`, `Referrals`, `Marketing`, `Processing` (read-model, no table),
`Events` (domain-event bus), `Webhooks` (org-scoped outbound delivery).

- **`Billing`** owns the vendor-agnostic payment provider contract + adapters.
  **`Credits`** is the internal usage ledger (`credit_events`, append-only;
  balance is derived). They are separate concerns.
- Tiers/prices are **config, not tables** (`Credits.Tier`, `Billing.Prices`).
- `Processing` composes reads from other contexts **through their context APIs**.

### Background jobs, Events, and Webhooks

**Oban** (OSS) is the background-job runner. Active queues: `:webhooks`. Async /
background work is now allowed — use Oban workers for any durable async task.

**`Events`** is the domain-event bus. Contexts call `Events.emit/2` **after their
DB transaction commits** — never inside an `Ecto.Multi` or before `Repo.transaction`
returns, because PubSub broadcast is synchronous and would race a
read-before-commit. `emit/2` fans out to in-process PubSub subscribers (for
LiveView) and schedules durable webhook delivery via Oban.

**`Webhooks`** owns org-scoped endpoint configuration, durable at-least-once
delivery (Oban queue `:webhooks`), HMAC-SHA256 signing (Stripe-style timestamped
header), and a deliveries log for auditability + replay.

## Web layer

- REST: `lib/perfect_paper_web/router/api/rest/*` — thin controllers → context
  calls; `FallbackController` for uniform errors. **History is the end-to-end
  reference controller.**
- Two auth surfaces: `user_auth.ex` (cookies + LiveView `on_mount`) and
  `tokens.ex` + `plugs/ApiAuth` (`Authorization: Bearer` = session token, else
  API key via `ApiKeys.verify/1`).
- LiveViews use **collocated templates**: `live/<resource>_live/home.ex` +
  `live/<resource>_live/home.html.heex`. They mirror the mutating REST calls 1:1.
- Realtime is **stubbed only** this pass: `perfect_paper_web/user_socket.ex` and
  `perfect_paper_web/channels/user_channel.ex` are no-op scaffolds for future
  realtime/collab — wired but inert.

## Out of scope (this pass — do not build without asking)

GraphQL/Absinthe · real payment vendors (stub only) · realtime/collab (PubSub
topics reserved, not built; the Events bus is built, channels are not) · any
React/TS/Clerk/Refine design-system carryover.

## Git & TDD workflow (every code change — no exceptions, no questions)

For ANY task that edits code:
1. **Cut your own fresh feature branch off `main`** — uniquely named, created by
   you, right now. **Never** commit to `main` directly and **never** reuse a
   branch someone else may be on.
2. **TDD: red → green → refactor.** Write the failing test first, make it pass,
   then clean up.
3. **Commit** on your branch, then **merge back to `main`** yourself.
4. Report exactly: **"committed and merged back to main with no issues."** Do not
   ask permission for branching/committing/merging — only stop if something
   genuinely unusual blocks the merge.

**Tests are 100% your responsibility.** "Everything passes except the tests that
aren't my fault" is never acceptable — a failing or broken test is your bug.
**Fix it before moving on.** Never claim success while any test is red.

## Commands

```bash
mix setup            # deps.get + ecto.setup + assets
mix ecto.setup       # create + migrate + seed
mix ecto.reset       # drop + setup
mix phx.server       # run (iex -S mix phx.server for a shell)
mix test             # creates/migrates test DB, runs ExUnit
mix precommit        # compile --warnings-as-errors, deps.unlock --unused, format, test
```

**Do not run the full `mix test` or `mix precommit` for every feature** — it's
slow and is the #1 way parallel agents step on each other. While developing, run
**only the tests covering your task** (e.g.
`mix test test/perfect_paper/history_test.exs`). Reserve the full suite /
`mix precommit` for an explicit pre-merge check.

## Testing

ExUnit with `DataCase`/`ConnCase` against real Postgres. Write tests **for the
scope of your task only**, and run **only those** while developing — not the
whole suite. New context work ships with its own context tests; new REST
controllers ship with their controller tests. Don't claim something passes
without running it, and **fix any test you break — no excuses, no "not my fault."**

## Working style here

- Match surrounding code; keep modules small and single-purpose.
- Calling `Repo` or a context's internals from **outside** that context? Stop —
  route through the context API. (Inside a context, submodule-to-submodule calls
  are fine.)
- Use the tarball (`perfect_paper.tar.gz`) only as a **read-only reference**, not
  a source to copy; its History context is a good idiomatic example.
