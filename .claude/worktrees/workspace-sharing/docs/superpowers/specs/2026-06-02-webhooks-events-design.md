# Webhooks + Event Bus (Oban) — Design (Spec 8)

**Date:** 2026-06-02
**Status:** Approved (reviewed; open questions resolved; signature + post-commit refinements folded in)
**Nature:** Real build. Adopts Oban, lifts the no-async/no-webhooks rule, and ships a shared domain-event bus + an org-scoped webhook subsystem with delivery, signing, retries, a deliveries log, REST CRUD, and a LiveView management page.

## Why / standing decision

The user approved adopting **Oban** and lifting the CLAUDE.md "async/SSE/background jobs (return 501)" + "webhooks out of scope" rule (recorded in memory `async-webhooks-scope-lifted`). Webhooks need durable outbound delivery (retries/backoff/signing) — i.e. background jobs — and "coincide with LiveView events" implies a domain-event → PubSub → dispatcher bus that webhooks, future realtime, and the Teams/Graph hooks (Spec 5) all share. So the **event bus is designed once** here and reused.

## Locked decisions (brainstorming)

| Decision | Choice |
|---|---|
| Event bus | A single `PerfectPaper.Events` context: a typed event envelope + `publish/1` that (a) PubSub-broadcasts for in-process consumers and (b) hands off to `Webhooks` for durable fan-out. |
| Subscriptions | **Org-scoped.** `webhook_endpoints` belong to an organization; created/managed by an org owner/admin (Authz-gated via the Spec 1 role check). |
| Initial events | `session.completed`, `comment.addressed`, `comment.dismissed`, `session.shared`, plus billing/credits (`subscription.updated`, `credits.low`). Taxonomy is extensible. |
| Delivery | Oban worker per (endpoint × event); **HMAC-SHA256** signature header; retries with backoff (Oban `max_attempts`); **at-least-once**; a `webhook_deliveries` log (attempts/status/response) — SOC 2 CC7 evidence. |
| Outbound HTTP | Behind a behaviour + **Req** adapter (anti-corruption layer, mirroring `Chatbot.LLM`); config-selected; a Stub adapter for tests. |
| Management | **Full**: `Webhooks` context API + REST CRUD (`/api/webhooks`, OpenAPI-documented per Spec 7) + a LiveView page (list endpoints, delivery log, redeliver). |
| Policy | **Update CLAUDE.md** — remove the no-async/no-webhooks "out of scope" lines; document Oban + the event-bus convention. (On THIS branch, since it's the webhooks work — not Spec 1's.) |

## Architecture

### Contexts (two new)

**`PerfectPaper.Events`** — the bus. No table of its own (events are transient + delivered; persistence of *deliveries* lives in Webhooks).
- `Events.Event` — an `embedded_schema`/struct envelope: `id` (uuid), `type` (atom, e.g. `:"session.completed"`), `occurred_at`, `organization_id` (for routing/tenancy), `resource` (type+id), `data` (map payload), `actor_id`. A changeset validates it (law 4: changeset on every write, even non-persisted).
- `Events.publish(event)` — validates the envelope, `Phoenix.PubSub.broadcast` on a per-type topic, and calls `Webhooks.dispatch(event)` (durable fan-out). Returns `:ok`.
- `Events.subscribe(type)` / topics — for in-process consumers (realtime, campaigns).
- A small `Events.emit(type, attrs)` helper contexts call at choke points (builds + publishes).

**`PerfectPaper.Webhooks`** — subscriptions + delivery. The only Repo/IO boundary for webhook data + outbound calls.
- Schemas: `Webhooks.Endpoint` (`organization_id`, `url`, `secret`, `event_types` (array of strings), `description`, `active`, timestamps) + `Webhooks.Delivery` (`endpoint_id`, `event_type`, `event_id`, `payload` (map/jsonb), `status` enum `[:pending, :delivered, :failed]`, `attempts`, `response_status`, `last_error`, `delivered_at`, timestamps).
- `dispatch(event)` — finds active org endpoints whose `event_types` include `event.type`, inserts a `Delivery` (pending) per match, and enqueues an Oban job per delivery. (Insert+enqueue in one `Ecto.Multi`/`Oban.insert` transaction so a delivery row always has a job.)
- `Webhooks.Delivery.Worker` (Oban worker) — loads the delivery, signs the payload **Stripe-style with the timestamp inside the signed string** (anti-replay): `ts = System.os_time(:second)`; `v1 = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{raw_json_body}") |> Base.encode16(case: :lower)`; header `X-PerfectPaper-Signature: t=<ts>,v1=<v1>` (+ `X-PerfectPaper-Event` + `X-PerfectPaper-Delivery`). Receivers recompute over `t + "." + body` and reject if `t` is outside a tolerance window. POSTs via the outbound adapter, records the attempt/status/response on the Delivery row. Non-2xx or transport error → raise/`{:error}` so Oban retries with backoff up to `max_attempts`; final failure marks `:failed`.
- Management API: `create_endpoint(org, scope, attrs)` (Authz/org-admin gated, generates a secret), `list_endpoints(org, scope)`, `update_endpoint`, `delete_endpoint`, `rotate_secret(endpoint, scope)`, `list_deliveries(endpoint, scope)`, `redeliver(delivery, scope)` (re-enqueues an Oban job).

### Outbound adapter (anti-corruption layer)
`Webhooks.Sender` behaviour — `@callback deliver(url, body, headers) :: {:ok, status} | {:error, term}`. Default `Webhooks.Sender.Req` (uses `Req.post`); `Webhooks.Sender.Stub` for tests (records calls, returns a configured result). Config key `:webhook_sender`. No vendor/HTTP specifics leak past the adapter.

### Oban
- Add `{:oban, "~> 2.x"}`; Oban migration (its own tables); supervise `{Oban, ...}` in `application.ex`; config queues (e.g. `webhooks: 10`) in `config.exs` + a `Oban.Testing`-friendly `testing: :manual` (or `:inline`) in `config/test.exs` so delivery jobs are asserted deterministically (no real HTTP in tests).

### Event emission points (contexts call `Events.emit`)
- `History.process_session` success → `session.completed`.
- `History` dismiss/address (in `act_on_comment`) → `comment.dismissed` / `comment.addressed`.
- `History.set_visibility(.., true)` → `session.shared`.
- `Billing` subscription change → `subscription.updated`; `Credits` low-balance signal → `credits.low`. (Emit from the existing context choke points; reuse the Credits PubSub precedent where natural.)
Each emission is **fire-and-safe and post-commit**: contexts call `Events.emit` **only after `Repo.transaction`/`Repo.*` returns `{:ok, result}`** — NEVER inside an `Ecto.Multi`. This is mandatory: `Phoenix.PubSub.broadcast` fires synchronously/immediately, so emitting inside the transaction would let an in-process subscriber query the DB for the resource before the originating transaction commits and get a spurious not-found (read-before-commit race). Publishing failures never break the originating operation (best-effort), and a missing/zero subscription set is a no-op.

### Web surface
- **REST** (`Api.WebhookController`, OpenAPI-annotated per Spec 7): `GET/POST /api/webhooks`, `GET/PATCH/DELETE /api/webhooks/:id`, `POST /api/webhooks/:id/rotate-secret`, `GET /api/webhooks/:id/deliveries`. Org-admin gated; secret returned only on create/rotate.
- **LiveView** (`WebhooksLive`): list org endpoints, create/edit/delete, view the delivery log (status, attempts, response, timestamps), and a **redeliver** button. Collocated template; discrete test ids; matches the `paper` theme. Org-admin gated via `on_mount`.

## Security
- Endpoint `secret` generated server-side (crypto-strong), shown once on create/rotate, stored for signing (TODO note: encrypt-at-rest later, consistent with the MFA CC6.7 gap).
- HMAC-SHA256 signature lets receivers verify authenticity. **Anti-replay: the timestamp is signed, not just sent** — `v1 = HMAC(secret, "<ts>.<raw_body>")`, header `t=<ts>,v1=<v1>` (Stripe-style). Hashing the body alone would let an attacker replay captured headers+body verbatim; binding `ts` into the MAC + a receiver-side tolerance window prevents it.
- SSRF consideration: validate endpoint URLs (https, public host) — at minimum reject non-http(s) and localhost/private ranges, or document the check as a `TODO(webhooks)` if deferred. **Decision: basic scheme+host validation in the Endpoint changeset this pass; deeper SSRF allow-listing noted as follow-up.**
- All management actions Authz/org-admin gated (reuse the Spec 1 / `Organizations.set_mfa_required` org-admin pattern).
- Delivery log is append-ish audit (SOC 2 CC7) — update `controls.md`/`evidence.md` to cite it.

## Testing
- `Events.publish` validates the envelope, broadcasts (assert via `Events.subscribe`), and calls `Webhooks.dispatch`.
- `Webhooks.dispatch` inserts deliveries + enqueues Oban jobs only for matching active endpoints (use `Oban.Testing` `assert_enqueued`).
- The delivery worker: with the Stub sender, a 2xx marks `:delivered`; a non-2xx/transport error increments attempts and (via Oban retry) eventually `:failed`. Signature header correct (verify HMAC).
- REST CRUD: org-admin can manage; non-admin gets 403; secret returned once. OpenAPI spec includes the new paths (extend the Spec 7 coverage test).
- LiveView: endpoint list/create/delete, delivery log renders, redeliver re-enqueues (assert_enqueued).
- Emission: `process_session` success enqueues a `session.completed` delivery for a subscribed org endpoint (integration).
- `config/test.exs` Oban `testing: :manual` so no real HTTP / async flakiness.

## Out of scope (this pass — TODO)
- Deep SSRF allow-listing / egress proxy (basic validation only now).
- Secret encryption-at-rest (column now; encryption a shared TODO with MFA CC6.7).
- Per-event delivery ordering guarantees / exactly-once (at-least-once only).
- Realtime channels (still stubbed; they'll consume the SAME `Events` bus later).
- Teams/Graph hooks (Spec 5 — will consume the bus).

## Definition of done
- Oban added/supervised/configured; CLAUDE.md updated (no-async/no-webhooks lines removed; Oban + event bus documented).
- `Events` context (envelope + publish + PubSub) and `Webhooks` context (endpoints, deliveries, dispatch, signed Oban delivery, retries, log, management API + secret rotation + redeliver), outbound behind a Req adapter (+ stub).
- Events emitted at the History (+ billing/credits) choke points.
- REST CRUD (OpenAPI-documented) + LiveView management page, both org-admin gated.
- Tests green incl. Oban (`testing: :manual`); `mix precommit` green.

## Resolved decisions (reviewed)
1. **Oban OSS** — sufficient (insert/retries/backoff/isolated queues). No Pro; the LiveView page covers the customer-facing management need.
2. **Compact payload** — `{type, occurred_at, organization_id, resource: {type, id}, data: {key fields incl. status}, links: {self: "<api url>"}}`. No full resource snapshot — keeps `webhook_deliveries` lean, avoids over-exposure, and forces consumers to fetch latest state (resolving delayed-delivery races).
3. **Billing/credits wired now** — emit `subscription.updated` + `credits.low` from the existing Billing/Credits choke points alongside the History events; proves the bus is genuinely cross-domain.
