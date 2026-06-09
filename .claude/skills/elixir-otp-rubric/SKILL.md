---
name: elixir-otp-rubric
description: Internal Elixir/OTP/Phoenix review standards (12 dimensions) used by the spec-editor and plan-editor subagents. Reference knowledge, not a user command.
user-invocable: false
---

# Elixir / OTP / Phoenix review standards

The shared standard of correctness for spec and plan review, written for a senior/staff reviewer. Review **specs at shape altitude** (boundaries, state ownership, contracts, data-safety, isolation) and **plans at mechanics altitude** (exact migrations, supervision wiring, lifecycle, locks, tests). Not every item applies to every artifact — mark `N/A` and move on. Cite the numbered standard on each finding (this feeds the audit log's `rubric_ref`). Do not invent findings to look thorough; a clean pass is `N/A` across the applicable items. The empirical gates (`mix compile --warnings-as-errors`, `credo --strict`, `dialyzer`, `mix test`) are the real backstop — a clean review never substitutes for a green suite.

## 1. Functional core, imperative shell
Hard logic is pure functions of their inputs that *return data* — including descriptions of effects (a struct, an `Ecto.Multi`). I/O, DB, process lifecycle, time, and randomness live at the edge. The litmus test is testability: if a business rule needs a sandbox, Mox, or a running process to test, the decision logic is tangled with effects. Purity is a means to reasoning and testability, not a religion — abstract only the seams with real variation; don't push everything behind a behaviour.
- Build an `Ecto.Multi` in the core (pure description of a transaction); `Repo.transaction/1` it in the shell.
- Time/randomness are effects: pass `now`/seed in, don't call `DateTime.utc_now/0` or `:rand` deep in logic.
- Changesets and validation are pure; the `Repo` call is the effect. `with` for happy-path flow, explicit `{:error, _}` tuples.
- **Flag:** decision logic calling `Repo`/`PubSub`/`GenServer.call` directly; functions untestable without a DB; `DateTime.utc_now/0`/`System`/`:rand` buried in core; "service" modules that fuse orchestration and rules.

## 2. The three Phoenix component types are not interchangeable (Phoenix 1.8 / LiveView 1.1)
- **LiveView** — a stateful websocket *process*, one per connected tab. `mount/3` runs **twice** (disconnected static render, then connected); it must be cheap, idempotent, and reload from params/session/DB on connect — never assume the first mount's work survives.
- **LiveComponent** — shares the parent LiveView's process (it is *not* its own process); a slow `handle_event/3` in it blocks the whole LiveView. Has `update/2`, `preload/1` (batch DB across instances → kill N+1), `@myself` targeting, `send_update/2`. Heavier than people assume.
- **Function component** (`Phoenix.Component`, typed `attr`/`slot`) — pure markup; the default building block and design system.
- 1.8 guidance leans **away** from LiveComponents: prefer a function component + `Phoenix.LiveView.JS` (client-side toggle/show/hide, no round-trip) or a separate LiveView; reach for a LiveComponent only when a subtree genuinely needs isolated *server* state + events. Most "I need a LiveComponent" is a function component + `JS`.
- **Collections → streams** (`phx-update="stream"`, scaffolded by the generators): the server doesn't hold the list and only diffs changes. A plain assign for a large list re-sends the whole list on any change. Don't stream things you must read back/aggregate server-side.
- Interactivity via `phx-hook`: **colocated hooks** (1.8+, `:type={Phoenix.LiveView.ColocatedHook}`, dot-prefixed name) for small/local JS; shared hooks in `assets/js` for reuse; DOM-owning hooks need `phx-update="ignore"`; `pushEvent`/`handleEvent`/`{:reply, map, socket}`. Forms: `to_form/2`, `<.form for={@form} id=…>`, `<.input>` with DOM ids, `phx-auto-recover` for reconnect recovery.
- **Flag:** long-lived state in a function component; a LiveComponent treated as its own process or doing blocking work; `mount` that assumes single execution or does unconditional expensive work; big collections in assigns instead of streams; a LiveComponent where a function component + `JS`/separate LV fits; DOM-owning hook missing `phx-update="ignore"`; per-instance N+1 that wants `preload/1`.

## 3. OTP is the concurrency model, not decoration
A GenServer **serializes** all access — it is a bottleneck, not a speed-up. Don't put a hot read path behind one.
- Shared read-mostly state → **ETS** (`read_concurrency: true`), `:persistent_term` (read-optimized, expensive writes), `:counters`/`:atomics` (lock-free). A GenServer is for coordination/serialization you actually need, or for owning a resource.
- `init/1` blocks the supervisor — do no slow work there; load in `handle_continue/2`. Avoid synchronous `call` cycles (A↔B) that deadlock.
- **Mailboxes are unbounded** → fast producer + slow consumer = memory blowup + latency. Backpressure with `GenStage`/`Broadway` (demand-driven) or bound work via `Task.Supervisor`/`Task.async_stream` (`max_concurrency`). Avoid large selective `receive` (O(n) mailbox scan).
- Discovery via `Registry` + `{:via, …}`, not global atom names; `DynamicSupervisor` for runtime children; `PartitionSupervisor` to shard one hot GenServer across cores.
- Every long-lived process under a supervisor with a deliberate strategy (`:one_for_one`/`:one_for_all`/`:rest_for_one`) **and restart intensity** (`max_restarts`/`max_seconds`) — a crash loop past intensity kills the parent. Child type matters: `:permanent` / `:transient` (only abnormal exit) / `:temporary`.
- "Let it crash" is for *unexpected* faults; expected conditions (bad input, not-found) are control flow → return `{:error, _}`, don't crash on a 404. And don't reach for a process when a pure function or a DB transaction is correct.
- **Flag:** bare `spawn`; unsupervised processes; global atom-named singletons that should be `Registry`/`DynamicSupervisor`; a GenServer on a hot read path (ETS fits); blocking work in `init/1`; unbounded mailbox / no backpressure; missing or default restart intensity; crashing on expected errors; "Elixir as MVC" where a process/pipeline fits — and the inverse, a process where a function/`Multi` fits.

## 4. Migration safety (zero-downtime by default; Postgres + Ecto)
Ecto wraps each migration in a transaction. **Concurrent index** needs `@disable_ddl_transaction true` **and** `@disable_migration_lock true` (Ecto warns/hangs otherwise) plus `create index(..., concurrently: true)`.
- Think in **lock levels**, not duration: most `ALTER TABLE` takes `ACCESS EXCLUSIVE` (blocks reads *and* writes); non-concurrent `CREATE INDEX` takes `SHARE` (blocks writes). The real hazard is a migration queuing behind a long query while holding/awaiting `ACCESS EXCLUSIVE` — it blocks *all* traffic to the table. Guard with `SET LOCAL lock_timeout` (+ `statement_timeout`) in `after_begin/0` so it **fails fast** instead of stalling the app.
- **Add column:** nullable, no *volatile* default (constant defaults are metadata-only in PG11+; volatile defaults rewrite the table). Backfill in a **separate** migration, batched, throttled to spare replicas.
- **NOT NULL:** a plain `SET NOT NULL` takes `ACCESS EXCLUSIVE` + full scan. Instead add `CHECK (col IS NOT NULL) NOT VALID`, then `VALIDATE CONSTRAINT` (only `SHARE UPDATE EXCLUSIVE`, doesn't block writes); PG12+ can then promote to a real `NOT NULL` using the validated constraint to skip the scan.
- **FK:** add `NOT VALID`, then `VALIDATE CONSTRAINT` separately.
- **Expand–contract across deploys is the actual skill:** schema and code must be compatible in *both* orders during a rolling deploy. Rename/type-change/drop is multi-step, multi-deploy (add new → backfill → write-both → read-new → drop old). Dropping a column is metadata-only but breaks old code still selecting it → expand-contract.
- Destructive/irreversible steps: explicit `up`/`down`, never data loss in `change`. Multi-node: Ecto's advisory migration lock interacts badly with PgBouncer transaction-mode pooling — know your pooler.
- **Flag:** index without `concurrently` on a populated table (or `concurrently` missing the two attrs); `SET NOT NULL`/`ADD FOREIGN KEY` without the `NOT VALID`→`VALIDATE` split; volatile default on add-column; schema change + backfill in one migration; no `lock_timeout`; rename/drop/type-change that breaks the running old code mid-rollout; unbatched/unthrottled backfill; destructive `change` with no reversible path.

## 5. Async test sandbox correctness
`async: true` ⇔ each test owns its own connection via `Ecto.Adapters.SQL.Sandbox` (`:manual` mode, checkout in `setup`), isolated in a transaction.
- The classic break: a process the test **spawns** (Task, GenServer, Oban job, the LiveView process itself) can't see the test's connection unless `Sandbox.allow(repo, owner, allowed)`, or you use `:shared` mode — and `:shared` **forces** `async: false`. LiveView tests spawn a process → need allow or shared.
- Global state that defeats async: `Application` env, `:persistent_term`, named processes/singletons, ETS singletons, the system clock, **Mox global mode** (use private mode + `set_mox_from_context` + `verify_on_exit!`, not `set_mox_global`), live Oban queues (use `Oban.Testing`, `:inline`/`:manual`), real network (stub via `Req.Test`/Mox).
- `async: false` is a **smell** — usually shared mutable global state that could be isolated; the serial cost compounds across a big suite.
- **Flag:** `async: true` with a spawned process lacking `allow`; tests mutating `Application` env / global singletons while async; Mox global mode under async; live Oban queue or real network in tests; reflexive `async: false` with no isolation attempt.

## 6. External boundaries: behaviours + mockable adapters (hexagonal)
Define the **port in your domain's terms** (a `@behaviour` for what *you* need), a thin adapter against the vendor, and a Mox mock chosen by config. The vendor's data model must **not** leak into the domain — translate at the adapter (anti-corruption).
- Select impl via `Application.compile_env` (compile-time, fast) or a runtime lookup if it must vary. `Mox.defmock` + `expect`/`stub`.
- Test the *adapter* against reality separately — `Req.Test` stubs (Req has first-class testing) or recorded cassettes/contract tests — so mock-green units don't hide a broken integration.
- Resilience lives in the adapter: timeouts, retries (idempotent only), circuit breaker, error normalization to your domain tuples.
- Over-abstraction is also a smell: a behaviour with one impl that will never change is ceremony. Abstract the seam you'll actually swap or fake.
- **Flag:** vendor SDK called from domain/context code; HTTP/`Req`/payment/LLM calls with no behaviour and no mock; vendor structs flowing into the domain unchanged; mocking only the HTTP client (mock-the-world) instead of a domain port; no timeout/retry/breaker; a behaviour that exists for no swap/test reason.

## 7. Context boundaries and DRY
Contexts are cohesive domain modules with a small public API — about **decoupling and cohesion**, not one-context-per-schema or CRUD wrappers (a context can own several schemas).
- Cross-context references **by ID, not by struct/association** — avoid Ecto associations that cross context lines (they create compile + data coupling). When contexts collaborate, go through the public API or a domain event; consider an anti-corruption/published-language layer between bounded contexts.
- Avoid the God context and the "schemas-as-API" leak (callers manipulating `%Billing.Invoice{}` internals).
- **DRY nuance:** the wrong abstraction costs more than duplication. Distinguish **essential** duplication (one rule that must change together → extract behind a *named domain concept*) from **incidental** (looks alike today, changes for unrelated reasons → leave separate). Grab-bag `Utils`/`Helpers` that everything depends on are as harmful as copy-paste — they couple unrelated code.
- **Flag:** trivial CRUD-per-schema contexts; cross-context Ecto associations / structs passed across boundaries; callers reaching into another context's schema internals; chatty cross-context calls; a God context; premature/over-extraction and generic helper modules; the same business rule in two places (including across spec & code).

## 8. Build vs borrow: BIFs, NIFs, packages
Reach for OTP/stdlib before deps: `:ets`, `:queue`, `:counters`, `:atomics`, `:persistent_term`, `Stream`, `Task.async_stream`, `:digraph`, `:gen_statem`. Most "we need X" is already in the stdlib.
- Judge a hex package on maintenance, last release, transitive-dep weight, and license — a dependency is a long-term liability, not free.
- **NIFs (Rustler)** only for a genuine hot path: a NIF running >~1ms blocks its scheduler (no preemption) → must be a **dirty NIF** or yield; a crashing/segfaulting NIF takes down the **whole VM** (no isolation). For risky native code prefer a crash-isolated **Port**/OS process. Most "we need Rust" is `:counters`/`:ets`/`:persistent_term` or a better algorithm.
- Write bespoke when small, core, and stable; borrow solved/broad problems (HTTP, JSON, crypto, money) — never hand-roll crypto or money math.
- **Flag:** bespoke reimplementation of a stdlib/OTP primitive or a solved problem; a heavy/unmaintained/incompatibly-licensed dep added casually; a NIF for non-hot-path work, or a long non-yielding/non-dirty NIF; hand-rolled crypto/money/parsing; native code that should be a crash-isolated Port.

## 9. Telemetry and observability
Emit `:telemetry.execute([:app, :context, :op], measurements, metadata)`; wrap risky/slow operations in `:telemetry.span/3` for start/stop/exception (duration + failure for free). Aggregate via `Telemetry.Metrics` + a reporter (Prometheus/StatsD) and LiveDashboard; structured logs with `Logger.metadata` + a correlation id.
- Measure the **four golden signals** (latency, traffic, errors, saturation) on the paths that matter: HTTP/LiveView mount+event latency; Ecto query time **and pool checkout/queue time** (saturation); external-call latency/error; **Oban queue depth and job latency**; mailbox length on bottleneck processes.
- Handlers run **synchronously in the emitting process** — a slow/exploding handler adds latency to (or crashes) the hot path. Keep them cheap; offload heavy work.
- Observability is designed in: any added process/queue/external call/expensive query with no measurement around it is an incomplete plan.
- **Flag:** new risky/slow path with no telemetry; expensive work in a telemetry/`Logger` handler on the hot path; no pool-checkout or queue-depth metric for added concurrency; no correlation id; logging secrets/PII (see §12).

## 10. End-user resilience (non-technical worker, spotty connection)
The killer assumption is "the socket is always up."
- LiveView **reconnect re-runs `mount` (connected)** → restore state from params/session/DB, never from lost socket assigns; design the reconnect path explicitly. `phx-disconnected`/`phx-connected` for UI; `phx-auto-recover` for forms.
- Optimistic UI must **reconcile against the server** (server is truth); use `Phoenix.LiveView.JS` for instant local affordances but converge on server state.
- Retryable actions need **idempotency** (see §11) so a post-drop re-send doesn't double-submit/double-charge.
- **Truly offline (the field tech in a basement) is the wrong job for LiveView** — it needs a REST/GraphQL API + local cache + sync-on-reconnect: idempotent push, delta pull with tombstones, a **monotonic per-org change cursor (not `updated_at`)**, and a written conflict policy. Don't paper offline over LiveView reconnection.
- Crashes must not lose user work; degrade gracefully; show human errors, not stacktraces; large lists via streams so a weak device isn't flooded.
- **Flag:** state restored from lost socket assigns on reconnect; optimistic UI with no server reconciliation; retryable mutation with no idempotency; "offline-first" hand-waved onto LiveView instead of an API + sync protocol; `updated_at` as a sync cursor; raw errors shown to users; assuming a perfect socket.

## 11. Concurrency correctness and data integrity
Under real concurrency, app-level checks race; the **database is the source of truth for invariants**.
- Enforce invariants with **DB constraints** (unique indexes, FKs, `CHECK`, exclusion) and handle violations idiomatically (`unique_constraint/3`, `foreign_key_constraint/3` on the changeset; `Repo.insert` returns the error, doesn't crash). A check-then-insert in app code is a race; a unique index is not.
- Multi-step writes are atomic via `Ecto.Multi` + `Repo.transaction` (with a rollback test).
- Contention: **optimistic locking** (`optimistic_lock` + `lock_version` → `Ecto.StaleEntryError`/`409` rebase) for low-contention edits; **pessimistic** `Ecto.Query.lock("FOR UPDATE")` or **advisory locks** for must-serialize sections (counter allocation, balance moves).
- Sequence/counter allocation must be atomic: `count(*)+1` races → `INSERT … ON CONFLICT … RETURNING` on a per-scope counter, or a Postgres sequence (concurrency-tested if gap-free is required).
- **Idempotency / at-least-once:** anything retryable (Oban jobs, webhooks, API mutations after a socket drop) needs an idempotency key + dedupe (Oban unique jobs **plus** a DB unique constraint as belt-and-suspenders); webhooks need duplicate/replay handling.
- Money is integer minor units, rounded once at the boundary; never float; `Decimal`/`ex_money` only at the edge.
- **Flag:** check-then-act races (uniqueness, balance, allocation) with no DB constraint; `count(*)+1` or read-modify-write counters; multi-step writes outside `Ecto.Multi`; contended rows with no lock strategy; retryable work with no idempotency key; float money.

## 12. Security and multi-tenant isolation
In a multi-tenant SaaS, isolation and authorization are correctness; the default must be **deny**.
- **Tenant-scope every query** by `org_id`/scope, enforced in the context (ideally a Repo-level backstop or Postgres RLS), never trusting a client-supplied `org_id`/param. Canonical attack to flag: a `*_id` param used to load a row without re-checking it belongs to the caller's tenant (**IDOR**). Tests must include a malicious cross-tenant id.
- **Authorize at the boundary**, deny-by-default; UI hiding is not enforcement. The page's `on_mount` is canonical for the route; the **context is canonical for the data**.
- **Mass-assignment:** `cast/3` allowlists only fields a user may set — never `cast` role/owner/`org_id`/price from user params.
- **`String.to_atom` on user/DB input is a DoS** (atom table isn't GC'd) → `String.to_existing_atom` or don't convert.
- Secrets from env, never committed config or logs; **redact PII before sending to third parties/LLMs** (per-org consent + no-train); validate/limit outbound URLs in adapters (SSRF). APIs: short-lived tokens + revocation; the magic-link/credential-prestuffing guards in `phx.gen.auth` exist on purpose — don't remove them.
- **Flag:** any query not tenant-scoped; trusting a client `org_id`/`*_id` without an ownership re-check (IDOR); authz only in UI/mount and not the context; `cast` allowing role/owner/price/org fields; `String.to_atom` on external input; secrets in repo/config or logged; PII/customer data to an LLM/third party without redaction+consent; outbound URL from user input with no SSRF guard.

## Severity calibration (drives the convergence loop and the audit `severity`)
- **Critical** — data loss/corruption, a security or tenant-isolation breach, a migration that locks a populated table, a race that double-charges, or anything that blocks implementation. Always loop.
- **Major** — wrong architecture, a process/lifecycle/concurrency defect needing structural rework, a missing contract or idempotency. Loop.
- **Minor** — non-idiomatic but correct, polish, naming. Log to `open_items`; do not loop.

## Output discipline
Per finding: `[Severity] [Meets / Fails]`, a one/two-sentence why citing the standard number, and a short non-idiomatic → idiomatic Elixir contrast **only** where it adds signal. Keep examples short. A clean pass is `N/A` across every applicable item.