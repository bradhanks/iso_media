# Perfect Paper — MVP Design (Synthesis / Greenfield)

**Date:** 2026-05-30
**Status:** Approved — proceeding to implementation plan
**Owner:** Brad Hanks

---

## 1. Background & decision

Perfect Paper is a refactor of **Refine.ink** (React frontend + Python/FastAPI
backend, Clerk auth) into a **Phoenix LiveView / Elixir** application. The goal of
the refactor is implementation flexibility and a path to realtime/collab
features that the original stack made hard.

Two prior attempts existed; both were evaluated harshly:

- **Committed tree (`HEAD`, "initial generators run"):** stock Phoenix **1.8**
  `mix phx.new` + `phx.gen.auth` + a pile of `phx.gen.live` CRUD. Verdict:
  **not salvageable as a domain.** Defects found:
  - Two migrations both named `create_documents`; one has a corrupted column
    literally generated as `add :"displa───────────", :string` (box-drawing
    garbage). As committed, `mix ecto.migrate` would fail on the duplicate table.
  - Several migrations share identical timestamps (non-deterministic order).
  - Generator-misplaced schemas (`marketing_preference`, `referral` dumped under
    `accounts/`); inconsistent naming (`billing` vs `subscriptions`).
  - **No API surface at all** — the `/api` scope is commented out in `router.ex`.
  - Generic CRUD LiveViews that do not match the product.
  - **Keepers:** the Phoenix 1.8 skeleton, `phx.gen.auth`/`user_auth.ex`, the
    test harness (`conn_case`/`data_case`). These are re-created greenfield.

- **Tarball (`perfect_paper.tar.gz`, one-shot agent):** hand-written port with
  the **right architecture** — functional core / imperative shell, ports with
  stubs, REST + GraphQL + LiveView matching the Refine surface. Verdict:
  **correct shape, unproven.** Never `mix compile`d, 8/11 contexts collapsed
  (changesets/queries inlined), async/payments stubbed, targets Phoenix 1.7.
  **Use as a read-only reference for "what good looks like," not as files to copy.**

- **`docs/openapi.json`:** referenced in prior notes but **not actually in the
  repo** (`git show HEAD:docs/openapi.json` → does not exist). The working
  contract is therefore the tarball's endpoint↔operation map plus the Ecto
  schemas in both trees and the owner's domain knowledge. If the real Refine
  OpenAPI spec is later added to `docs/`, reconcile against it.

**Decision:** Full **greenfield** on Phoenix 1.8, rebuild the domain and web
layers to a strict standard, REST + LiveView only.

---

## 2. Scope

### In scope (this pass)
- Greenfield Phoenix 1.8 app + `phx.gen.auth` (local auth, `user_auth.ex`).
- Postgres, `binary_id` primary keys, Bandit.
- **All ~11 contexts modeled** to the strict architecture (context API + schema
  + changeset + query, with `@spec`/`@type`).
- **Core vertical fully wired + tested:** `Accounts`, `ApiKeys`, `History`,
  and the `Credits` read path (`credit-score`).
- **Side-effecting contexts behind config-selected behaviour adapters with
  stubs:** `Chatbot` (LLM), `Documents` (Storage), `Billing` (payment provider).
- **REST API** (built incrementally, History is the end-to-end reference) +
  **LiveView** for the core.
- **Styling:** Phoenix 1.8's native Tailwind v4 + daisyUI baseline, components
  built with the **daisyUI-blueprint MCP** (`daisyUI-Snippets`, `Figma-to-daisyUI`).
- **Stubbed realtime scaffolds:** `perfect_paper_web/user_socket.ex` and
  `perfect_paper_web/channels/user_channel.ex` exist as wired-but-inert no-ops so
  the future realtime/collab work has a landing spot.

### Out of scope (deferred, explicitly)
- **GraphQL / Absinthe** — REST only this pass (one API to build and test at a time).
- **Webhooks** — no payment-provider webhooks.
- **Async / SSE / background jobs** — endpoints needing them return `501`.
  PubSub topics are reserved (not built) for future realtime/collab.
- Real payment-vendor wiring (Stripe etc.) — behaviour + stub only.
- Anything React / TypeScript / Clerk / Refine's own design system.

---

## 3. Architecture laws (non-negotiable; enforced by `CLAUDE.md` + review)

1. **One context module = the only public API and the only `Repo`/IO boundary.**
   Other contexts and the web layer call *only* `PerfectPaper.<Context>` functions.
2. **Schemas carry their own changesets; queries live with the business logic.**
   - `<context>/<schema>.ex` — Ecto schema (fields + `@type`) **and** its
     changeset function(s); changesets are pure (`Ecto.Changeset`, no `Repo`).
   - **Queries are written inline** in the `<context>.ex` function that uses
     them (most are a `Repo.get`/`Repo.get_by` or small `from`). Promote a
     filter/scope to a **named builder only to remove duplication** when it
     repeats across functions — usually a private fn in the context. A collection
     of query functions for its own sake is an anti-pattern.
   - Split a dedicated `<schema>/changeset.ex` or `<schema>/query.ex` module out
     **only** when that logic is large/involved — not by default.
3. **Contexts are the boundary, not submodules.** Treat each context as
   standalone as far as practical; **cross-context** access goes through context
   APIs only (shared leaves like `PerfectPaper.Types` and the mailer excepted).
   **Within** a context, submodules may call siblings and other files freely —
   just prefer not to reach deep into another submodule's internals, and keep
   related code in its own subfolder where natural. Not a hard rule.
4. **Changeset on every write — even non-persisted data.** Inbound params,
   adapter results destined for structs, and validation boundaries use
   `Ecto.Changeset` (schemaless or `embedded_schema`). The DB layer holds **no
   business logic**.
5. **Typespecs everywhere.** Every public function has `@spec`; structs/contexts
   have `@type`. `@moduledoc`/`@doc` on public modules and functions.
6. **Business-readable names.** Context functions read as the steps a human in
   that role would take — `History.dismiss_comment(session_id, comment_id, by: user_id)`,
   `Credits.charge_for_proofreading(user)`, `Billing.upgrade_plan(...)`.
   A non-engineer should be able to read the context API.
7. **Side-effects sit behind a behaviour with a config-selected adapter** acting
   as an anti-corruption layer. No vendor JSON keys, error codes, or API details
   leak past the adapter. Adapters return atom-keyed maps matching Ecto schema
   fields so callers pass them straight to changesets.
8. **`precommit` gate:** `mix compile --warnings-as-errors`, `deps.unlock
   --unused`, `mix format`, `mix test` must pass.

---

## 4. Directory layout

```
lib/perfect_paper/
  <context>.ex                      # PUBLIC API + sole Repo/IO boundary + most queries
  <context>/<schema>.ex            # Ecto schema + its changeset(s), together
  <context>/<port>.ex              # behaviour (e.g. billing/provider.ex)
  <context>/<port>/<adapter>.ex    # adapter impl (e.g. billing/stub_adapter.ex)
  types.ex                         # shared leaf types/utilities
  # Optional, only when a piece gets large:
  #   <context>/<schema>/changeset.ex   # big changeset logic
  #   <context>/<schema>/query.ex       # rare: large standalone query module

lib/perfect_paper_web/
  router.ex                         # browser + LiveView; forwards /api
  router/api/rest.ex                # REST router
  router/api/rest/*_controller.ex   # thin controllers -> context calls
  router/api/rest/fallback_controller.ex
  live/<resource>_live/home.ex      # LiveView module
  live/<resource>_live/home.html.heex  # collocated template
  plugs/api_auth.ex                 # Bearer (session token OR API key)
  tokens.ex + tokens/               # token facade (bearer, socket)
  user_auth.ex                      # phx.gen.auth session/LiveView auth
  user_socket.ex                    # STUBBED — inert scaffold for future realtime
  channels/user_channel.ex          # STUBBED — inert scaffold for future realtime
  types/uuid4.ex
```

---

## 5. Contexts

| Context | Sample public API (business verbs) | Tables | Status this pass |
|---|---|---|---|
| **Accounts** | `register_user`, `get_user_by_email`, `get_user_by_email_and_password`, `create_session_token`, `delete_session_token` | `users`, `users_tokens` | **Wired + tested** (phx.gen.auth) |
| **ApiKeys** | `generate`, `list_keys`, `revoke_key`, `verify` | `api_keys` | **Wired + tested** |
| **History** | `list_sessions`, `get_session`, `get_session_with_feedback`, `begin_session`, `record_progress`, `finish_session`, `delete_session`, `dismiss_comment`, `address_comment`, `undo_comment_action`, `set_visibility`, `mark_viewed`, `request_access` | `history_sessions`, `comments`, `comment_actions` | **Wired + tested — reference vertical** |
| **Credits** | `balance`, `grant`, `charge_for_proofreading`, `limits_for` | `credit_events` (+ `Tier` pure config) | **Read path (`credit-score`) wired + tested**; charging wired |
| **Chatbot** | `open_conversation`, `post_user_message`, `answer`, `delete_conversation` | `conversations`, `chat_messages` | Modeled; `Chatbot.LLM` behaviour + `Stub` |
| **Documents** | `register_upload`, `mark_converted`, `read_content`, `list_appendices` | `documents` (self-ref appendices) | Modeled; `Documents.Storage` behaviour + `Local`; async processing → `501` |
| **Billing** | `get_subscription_for_user`, `upgrade_plan`, `downgrade_plan`, `cancel_plan`, `list_products` | `subscriptions` (+ `Prices` pure config) | Modeled; `Billing.Provider` behaviour + `StubAdapter`; webhooks out |
| **Organizations** | `credit_pool_status`, `allocate_credits_to_member`, `return_credits_to_pool`, `request_credits` | `organizations`, `memberships` | Modeled |
| **Referrals** | `register`, `status` | `referrals` | Modeled |
| **Marketing** | `get_preferences`, `set_opt_in` | `marketing_preferences` | Modeled |
| **Processing** | `snapshot`, `active_items`, `unviewed_items` | *(read-model — no table)* | Modeled; reads via `History`/`Documents` context APIs |

Notes:
- **`Billing`** owns the vendor-agnostic provider contract and adapters (per the
  owner's anti-corruption example). It is distinct from **`Credits`**, which is
  the internal usage ledger.
- Document size tiers (`default | extended | unlimited`) and plan prices are
  **config, not tables** (`Credits.Tier`, `Billing.Prices`).
- "Modeled" = full context API + schema(s) + changeset(s) + query(s) compiling
  to the strict standard, with side-effects behind stubbed adapters; not yet
  exercised end-to-end by tests this pass.

---

## 6. Vendor / side-effect adapter pattern

Every genuine side-effect is a behaviour + config-selected adapter:

| Concern | Behaviour | Default adapter (this pass) | Future |
|---|---|---|---|
| Payments | `PerfectPaper.Billing.Provider` | `Billing.StubAdapter` | `Billing.StripeAdapter` |
| Language model | `PerfectPaper.Chatbot.LLM` | `Chatbot.LLM.Stub` | real LLM client |
| Blob storage | `PerfectPaper.Documents.Storage` | `Documents.Storage.Local` | S3/GCS |

- Adapter selected via `config :perfect_paper, :billing_provider, …` (etc.).
- The behaviour defines `@callback`s with full typespecs; the adapter is the
  **only** module allowed to reference vendor specifics and the only one that
  performs the external call.
- Adapters return atom-keyed maps matching Ecto schema fields so the context can
  pass results directly into changesets without translation.

---

## 7. Web layer (REST + LiveView)

- **REST:** `router/api/rest.ex` forwarded under `/api`. Thin controllers call
  context APIs and render JSON. `FallbackController` provides a uniform error
  envelope. **History endpoints are the end-to-end reference**; others call
  their (possibly stubbed) contexts. Endpoints requiring async/webhooks return
  `501`.
- **Auth surfaces, kept apart:**
  - `user_auth.ex` — cookies + LiveView `on_mount` (browser side, phx.gen.auth).
  - `tokens.ex` + `plugs/ApiAuth` — `Authorization: Bearer <value>` tried first
    as a **session token**, then as an **API key** (`ApiKeys.verify/1`).
- **LiveView:** core resources (`HistoryLive`) mirror the mutating REST calls
  1:1 (`dismiss`/`address`/`undo`/`toggle_visibility`). **Collocated templates**
  (`<resource>_live/home.ex` + `home.html.heex`). Styled with Phoenix 1.8 daisyUI
  + daisyUI-blueprint snippets.
- **Realtime (stubbed):** `user_socket.ex` + `channels/user_channel.ex` are inert
  scaffolds only; no channels wired this pass.

---

## 8. Data model & migrations

- One clean, ordered migration set (no duplicate/garbage migrations). `binary_id`
  PKs throughout. Enums stored as strings (Ecto `Ecto.Enum`).
- `documents` is self-referential (appendices via `parent_document_id`).
- `history_sessions` carries `processing_status` (`pending | converting |
  analyzing | complete | failed`), `is_public`, `viewed`.
- `credit_events` is an append-only ledger; balance is derived.

---

## 9. Testing & definition of done

- **Tests:** ExUnit with `DataCase`/`ConnCase`. Per-context tests for
  `Accounts`, `History`, `ApiKeys`, `Credits` (read) against real Postgres;
  REST controller tests for the History surface; a smoke LiveView test for
  `HistoryLive`.
- **Scoped runs only.** Write and run tests **for the scope of the task at hand**
  — `mix test path/to/that_test.exs`, not the whole suite. Running full
  `mix test`/`mix precommit` per feature is slow and the main cause of parallel
  work colliding; reserve it for an explicit pre-merge check.
- **Done when:**
  1. `mix compile` is clean under `--warnings-as-errors`.
  2. `mix phx.server` boots.
  3. The History **REST + LiveView** flow works under auth (Bearer = session or API key).
  4. The core test suite is green against Postgres.
  5. `CLAUDE.md` codifies the architecture laws and scope.

---

## 10. Deferred backlog (post-MVP)

**APIs & integrations**
- GraphQL (Absinthe-native) parallel surface.
- Payment-provider webhooks + real `StripeAdapter`.
- Real LLM and blob-storage adapters.
- Async upload/process pipeline + SSE/channels.

**Org & access model**
- **`Teams`** — a layer between `User` and `Organization` (User → Team →
  Organization hierarchy); credit pools and membership likely extend down to teams.
- **Sharing roles (Google-Drive-style)** on a paper/session: `viewer` (view-only),
  `commenter` (comment-only), `editor`, `author`/owner. Drives access checks on
  History sessions and documents.

**Realtime collaboration** (the reason for the Phoenix refactor)
- Per-paper presence + live co-editing/co-review via PubSub on `"session:<id>"`,
  using the stubbed `user_socket`/`user_channel` scaffolds.
- **Per-paper chat:** discuss a paper with collaborators in-thread.
- **Shared comments:** leave comments on a paper for other collaborators to see
  (distinct from the AI proofreading comments) — visibility governed by the
  sharing roles above.

**Hardening**
- Full end-to-end wiring + tests for the "modeled" contexts.
