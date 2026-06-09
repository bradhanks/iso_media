# Webhooks + Event Bus (Oban) — Implementation Plan (Spec 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** A shared `Events` bus (typed envelope → PubSub + durable Oban fan-out) + an org-scoped `Webhooks` subsystem (endpoints, signed at-least-once delivery with retries + a deliveries log) behind a Req outbound adapter; events emitted post-commit at the History/Billing/Credits choke points; REST CRUD + a LiveView management page; and the `CLAUDE.md` policy edit (Oban + no-async rule lifted).

**Architecture:** `Events` (transient domain routing) and `Webhooks` (durable external delivery) are separate contexts. `dispatch` inserts a `Delivery` row + enqueues its Oban job in one `Ecto.Multi`/`Oban.insert` (at-least-once). The worker signs Stripe-style (`v1 = HMAC(secret, "<ts>.<body>")`, header `t=,v1=`) and delivers via a config-selected `Sender` adapter (Req default, Stub in tests). Emission is **post-commit only** (never inside a Multi) to avoid PubSub read-before-commit.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto/Postgres, **Oban (OSS) ~> 2.x**, Req ~> 0.5 (present), Phoenix.PubSub (present). Spec: `docs/superpowers/specs/2026-06-02-webhooks-events-design.md`.

## Conventions
- Architecture laws: `Events`/`Webhooks` are the only public APIs + Repo/IO boundaries for their concerns; schemas carry changesets; `@spec`/`@type`/`@moduledoc` throughout; management writes Authz/org-admin gated (reuse the `Organizations.set_mfa_required/3` owner-or-admin pattern).
- Oban tests: `config/test.exs` sets Oban `testing: :manual`; tests use `Oban.Testing` (`assert_enqueued`, `Oban.drain_queue`/`perform_job`). NO real HTTP in tests (Stub sender).
- `TODO(webhooks):` tag for deferred items (secret-at-rest encryption, deep SSRF allow-listing).

---

## Task 1: Oban setup

**Files:** `mix.exs`; an Oban migration `priv/repo/migrations/20260602120000_add_oban.exs`; `lib/perfect_paper/application.ex`; `config/config.exs`; `config/test.exs`; test `test/perfect_paper/oban_test.exs`.

- [ ] **Step 1 — dep.** Add `{:oban, "~> 2.18"}` (latest 2.x via `mix hex.info oban`). `mix deps.get`.
- [ ] **Step 2 — migration.** `priv/repo/migrations/20260602120000_add_oban.exs`:
```elixir
defmodule PerfectPaper.Repo.Migrations.AddOban do
  use Ecto.Migration
  def up, do: Oban.Migration.up(version: 12)
  def down, do: Oban.Migration.down(version: 1)
end
```
(Use the current Oban migration version per its docs.)
- [ ] **Step 3 — config.** `config/config.exs`: `config :perfect_paper, Oban, repo: PerfectPaper.Repo, queues: [webhooks: 10], plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]`. `config/test.exs`: `config :perfect_paper, Oban, testing: :manual` (+ repo). `config/dev.exs` keep default queues.
- [ ] **Step 4 — supervise.** In `lib/perfect_paper/application.ex` children, add `{Oban, Application.fetch_env!(:perfect_paper, Oban)}` (before the Endpoint; after Repo/PubSub).
- [ ] **Step 5 — failing test** `test/perfect_paper/oban_test.exs`:
```elixir
defmodule PerfectPaper.ObanTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  test "oban is configured and a job can be enqueued" do
    assert {:ok, _} = Oban.insert(Oban.Job.new(%{}, worker: "FakeWorker", queue: :webhooks))
    assert_enqueued(worker: "FakeWorker", queue: :webhooks)
  end
end
```
- [ ] **Step 6 — migrate dev+test, run PASS.** `mix ecto.migrate`, `MIX_ENV=test mix ecto.migrate`, `mix test test/perfect_paper/oban_test.exs`. `mix compile --warnings-as-errors` clean.
- [ ] **Step 7 — commit:** `git add -A && git commit -m "feat(oban): add Oban (OSS) — migration, supervision, config, testing :manual"`

---

## Task 2: `Events` context (envelope + publish + emit)

**Files:** `lib/perfect_paper/events.ex`; `lib/perfect_paper/events/event.ex`; test `test/perfect_paper/events_test.exs`.

- [ ] **Step 1 — failing test** `test/perfect_paper/events_test.exs`:
```elixir
defmodule PerfectPaper.EventsTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Events

  test "emit validates and broadcasts to subscribers of the type" do
    Events.subscribe(:"session.completed")
    org_id = Ecto.UUID.generate()
    assert :ok = Events.emit(:"session.completed", %{organization_id: org_id, resource: %{type: :session, id: Ecto.UUID.generate()}, data: %{status: "complete"}})
    assert_receive {:event, %PerfectPaper.Events.Event{type: :"session.completed", organization_id: ^org_id}}
  end

  test "emit rejects an unknown event type" do
    assert {:error, %Ecto.Changeset{}} = Events.emit(:"bogus.event", %{})
  end
end
```
- [ ] **Step 2 — run FAIL.**
- [ ] **Step 3 — Event envelope** `lib/perfect_paper/events/event.ex`:
```elixir
defmodule PerfectPaper.Events.Event do
  @moduledoc "A domain event envelope. Transient (not persisted by Events); validated before publish."
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(session.completed comment.addressed comment.dismissed session.shared subscription.updated credits.low)a

  @type t :: %__MODULE__{}
  @primary_key false
  embedded_schema do
    field :id, :binary_id
    field :type, Ecto.Enum, values: @types
    field :occurred_at, :utc_datetime_usec
    field :organization_id, :binary_id
    field :actor_id, :binary_id
    field :resource, :map
    field :data, :map, default: %{}
  end

  @doc "Validates an event envelope."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:id, :type, :occurred_at, :organization_id, :actor_id, :resource, :data])
    |> validate_required([:type])
  end

  @doc "All known event types."
  @spec types() :: [atom()]
  def types, do: @types
end
```
- [ ] **Step 4 — Events context** `lib/perfect_paper/events.ex`:
```elixir
defmodule PerfectPaper.Events do
  @moduledoc """
  The domain event bus. Contexts call `emit/2` AFTER their DB transaction commits
  (never inside an Ecto.Multi — PubSub broadcast is synchronous and would race a
  read-before-commit). Each event is broadcast on PubSub (in-process consumers:
  realtime, campaigns) and handed to `Webhooks.dispatch/1` for durable fan-out.
  """
  alias PerfectPaper.Events.Event
  alias PerfectPaper.Webhooks

  @spec topic(atom()) :: String.t()
  def topic(type), do: "events:#{type}"

  @spec subscribe(atom()) :: :ok | {:error, term()}
  def subscribe(type), do: Phoenix.PubSub.subscribe(PerfectPaper.PubSub, topic(type))

  @doc "Builds, validates, and publishes an event. Call AFTER the originating transaction commits."
  @spec emit(atom(), map()) :: :ok | {:error, Ecto.Changeset.t()}
  def emit(type, attrs) do
    attrs = attrs |> Map.put(:type, type) |> Map.put_new(:id, Ecto.UUID.generate())

    case Event.changeset(attrs) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, event} -> publish(event)
      {:error, cs} -> {:error, cs}
    end
  end

  @doc "Publishes an already-built event: PubSub broadcast + durable webhook dispatch."
  @spec publish(Event.t()) :: :ok
  def publish(%Event{} = event) do
    Phoenix.PubSub.broadcast(PerfectPaper.PubSub, topic(event.type), {:event, event})
    Webhooks.dispatch(event)
    :ok
  end
end
```
(NOTE: `occurred_at` defaults can't use `DateTime.utc_now()` in a module attr; set it in `emit` via `Map.put_new(:occurred_at, DateTime.utc_now())` — add that to the `attrs` pipeline. `Webhooks.dispatch/1` is built in Task 4; for THIS task, either stub `Webhooks.dispatch/1` to return `:ok` or order Task 4 before wiring the call — simplest: add a temporary `defp` no-op and replace in Task 4, OR implement Tasks 3+4 first then Events. RECOMMENDED ORDER NOTE: if `Webhooks` doesn't exist yet, make `publish` call `Webhooks.dispatch(event)` only if `Code.ensure_loaded?` — NO; instead, build Task 3+4 (Webhooks) BEFORE Task 2's `publish` references it. The controller will re-sequence: do Webhooks schemas/dispatch first if needed. For this plan, Task 2 may temporarily define `publish` without the `Webhooks.dispatch` line and Task 4 adds it.)
- [ ] **Step 5 — run PASS** (the broadcast test; the dispatch line added in Task 4). Compile clean.
- [ ] **Step 6 — commit:** `git add -A && git commit -m "feat(events): domain event bus — validated envelope + emit/publish (PubSub)"`

---

## Task 3: `Webhooks` schemas + migration

**Files:** migration `priv/repo/migrations/20260602120100_create_webhooks.exs`; `lib/perfect_paper/webhooks/endpoint.ex`; `lib/perfect_paper/webhooks/delivery.ex`; tests.

- [ ] **Step 1 — migration:**
```elixir
defmodule PerfectPaper.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration
  def change do
    create table(:webhook_endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :url, :string, null: false
      add :secret, :string, null: false
      add :event_types, {:array, :string}, null: false, default: []
      add :description, :string
      add :active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end
    create index(:webhook_endpoints, [:organization_id])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :endpoint_id, references(:webhook_endpoints, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :event_id, :binary_id
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :response_status, :integer
      add :last_error, :string
      add :delivered_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end
    create index(:webhook_deliveries, [:endpoint_id])
    create index(:webhook_deliveries, [:status])
  end
end
```
- [ ] **Step 2 — Endpoint schema** `lib/perfect_paper/webhooks/endpoint.ex`: fields per migration; `create_changeset` casts `[:organization_id, :url, :secret, :event_types, :description, :active]`, requires `[:organization_id, :url, :secret]`, validates `url` is `http(s)` and host is not localhost/private (basic SSRF guard — `validate_change`/regex; deeper allow-listing is `TODO(webhooks):`), validates each `event_types` entry is in `PerfectPaper.Events.Event.types() |> Enum.map(&to_string/1)`. `update_changeset` (url/event_types/description/active). `@type/@moduledoc/@spec/@doc`.
- [ ] **Step 3 — Delivery schema** `lib/perfect_paper/webhooks/delivery.ex`: fields per migration; `status` Ecto.Enum `[:pending, :delivered, :failed]`; `create_changeset` (endpoint_id, event_type, event_id, payload); `attempt_changeset(delivery, attrs)` (status, attempts, response_status, last_error, delivered_at). `@type/@moduledoc/@spec/@doc`.
- [ ] **Step 4 — tests** (`endpoint_test.exs`, `delivery_test.exs`): required-field validation; URL validation rejects `ftp://`/`http://localhost`; event_types validation rejects an unknown type; valid cases. Run PASS (migrate first).
- [ ] **Step 5 — commit:** `git add -A && git commit -m "feat(webhooks): endpoint + delivery tables/schemas (URL + event-type validation)"`

---

## Task 4: `Webhooks.dispatch` + delivery worker + Sender adapter

**Files:** `lib/perfect_paper/webhooks.ex` (dispatch + worker enqueue); `lib/perfect_paper/webhooks/delivery/worker.ex`; `lib/perfect_paper/webhooks/sender.ex` (behaviour) + `.../sender/req.ex` + `.../sender/stub.ex`; `config/config.exs` + `config/test.exs` (`:webhook_sender`); wire `Events.publish` to call `Webhooks.dispatch`; tests.

- [ ] **Step 1 — Sender behaviour + adapters.** `lib/perfect_paper/webhooks/sender.ex`: `@callback deliver(url :: String.t(), body :: String.t(), headers :: [{String.t(), String.t()}]) :: {:ok, status :: integer()} | {:error, term()}`. `sender/req.ex` uses `Req.post(url, body: body, headers: headers)` → `{:ok, status}`/`{:error, _}`. `sender/stub.ex` records into the process/an Agent and returns a configured result (default `{:ok, 200}`). Config: `config :perfect_paper, :webhook_sender, PerfectPaper.Webhooks.Sender.Req` in config.exs; `...Sender.Stub` in test.exs.
- [ ] **Step 2 — dispatch** in `lib/perfect_paper/webhooks.ex`:
```elixir
  @doc "Fan out an event to matching active org endpoints: insert a Delivery + enqueue its Oban job atomically."
  @spec dispatch(PerfectPaper.Events.Event.t()) :: :ok
  def dispatch(%PerfectPaper.Events.Event{organization_id: nil}), do: :ok
  def dispatch(%PerfectPaper.Events.Event{} = event) do
    for endpoint <- matching_endpoints(event.organization_id, event.type) do
      payload = build_payload(event)
      Repo.transaction(fn ->
        {:ok, delivery} = %Delivery{} |> Delivery.create_changeset(%{endpoint_id: endpoint.id, event_type: to_string(event.type), event_id: event.id, payload: payload}) |> Repo.insert()
        {:ok, _job} = %{delivery_id: delivery.id} |> Webhooks.Delivery.Worker.new() |> Oban.insert()
      end)
    end
    :ok
  end
```
`matching_endpoints/2`: active endpoints in the org whose `event_types` contains `to_string(type)` (inline query, `fragment("? = ANY(...)")` or `^type in e.event_types`). `build_payload/1`: the compact map `%{type, occurred_at, organization_id, resource, data, links: %{self: ...}}` (best-effort `links.self` from the resource type+id + endpoint config host; if no clean URL, omit links).
- [ ] **Step 3 — worker** `lib/perfect_paper/webhooks/delivery/worker.ex`: `use Oban.Worker, queue: :webhooks, max_attempts: 5`. `perform/1` loads the delivery + endpoint; builds `raw_body = Jason.encode!(delivery.payload)`; `ts = System.os_time(:second)`; `v1 = :crypto.mac(:hmac, :sha256, endpoint.secret, "#{ts}.#{raw_body}") |> Base.encode16(case: :lower)`; headers `[{"content-type","application/json"},{"x-perfectpaper-event", delivery.event_type},{"x-perfectpaper-delivery", delivery.id},{"x-perfectpaper-signature","t=#{ts},v1=#{v1}"}]`; calls `sender().deliver(endpoint.url, raw_body, headers)`. On `{:ok, status}` with 2xx → `attempt_changeset` status :delivered, response_status, delivered_at, attempts+1 → `:ok`. On non-2xx or `{:error,_}` → record attempt (status stays :pending or set :failed on last attempt via `Oban.Worker.timeout`/attempt count), increment attempts, last_error, and RETURN `{:error, reason}` so Oban retries. (Use the job's `attempt`/`max_attempts` to set `:failed` on the final attempt.) `sender()` reads `Application.get_env(:perfect_paper, :webhook_sender, ...Req)`.
- [ ] **Step 4 — wire Events.publish** to call `Webhooks.dispatch(event)` (add the line deferred in Task 2).
- [ ] **Step 5 — tests** `test/perfect_paper/webhooks_test.exs` (use `Oban.Testing`):
  - `dispatch` for an event with a matching active endpoint inserts a pending Delivery + `assert_enqueued(worker: Webhooks.Delivery.Worker)`; non-matching/ inactive → none.
  - worker with Stub sender returning `{:ok, 200}`: `perform_job` marks delivery :delivered, attempts 1. Stub returning `{:ok, 500}`: returns `{:error,_}` (Oban retry), attempts incremented, not delivered.
  - signature: capture the headers in the Stub, recompute `HMAC(secret, "<t>.<body>")`, assert it matches `v1`.
  - end-to-end: `Events.emit(:"session.completed", %{organization_id: org.id, ...})` with a subscribed endpoint → `assert_enqueued`.
- [ ] **Step 6 — run PASS; commit:** `git add -A && git commit -m "feat(webhooks): dispatch + signed Oban delivery worker (Stripe-style HMAC) + Req/Stub sender"`

---

## Task 5: `Webhooks` management API (org-admin gated)

**Files:** `lib/perfect_paper/webhooks.ex`; fixtures `test/support/fixtures/webhooks_fixtures.ex`; test append.

- [ ] **Step 1 — functions** (Authz/org-admin gated, reusing the owner-or-admin check pattern from `Organizations.set_mfa_required/3` — call `Organizations` to check admin, or replicate): `create_endpoint(org, scope, attrs)` (generates `secret` via `:crypto.strong_rand_bytes(32) |> Base.url_encode64`), `list_endpoints(org, scope)`, `get_endpoint(id, scope)`, `update_endpoint(endpoint, scope, attrs)`, `delete_endpoint(endpoint, scope)`, `rotate_secret(endpoint, scope)` (new secret, returns it), `list_deliveries(endpoint, scope, opts)`, `redeliver(delivery, scope)` (enqueue a fresh worker job, reset to :pending). Each gated: non-admin → `{:error, :unauthorized}`. `@spec`/`@doc`.
- [ ] **Step 2 — fixtures** `webhooks_fixtures.ex`: `endpoint_fixture(org, attrs \\ %{})` inserting an active endpoint subscribed to `["session.completed"]`.
- [ ] **Step 3 — tests:** org owner/admin can create/list/update/delete/rotate; non-admin/stranger → `{:error, :unauthorized}`; create returns a secret; rotate changes it; redeliver `assert_enqueued`. Run PASS.
- [ ] **Step 4 — commit:** `git add -A && git commit -m "feat(webhooks): management API (CRUD + rotate_secret + redeliver), org-admin gated"`

---

## Task 6: Emit events at the choke points (post-commit)

**Files:** modify `lib/perfect_paper/history.ex`, `lib/perfect_paper/billing.ex`, `lib/perfect_paper/credits.ex`; tests.

- [ ] **Step 1 — History.** AFTER the `Repo.transaction` in `process_session` returns `{:ok, _}` (the success branch, NOT inside the Multi), emit `:"session.completed"` with `%{organization_id: org_id_of(session), actor_id: session.owner_id, resource: %{type: :session, id: session.id}, data: %{title: ..., status: "complete"}}`. In `act_on_comment` AFTER the transaction commits, emit `:"comment.addressed"`/`:"comment.dismissed"`. In `set_visibility` AFTER update with `is_public: true`, emit `:"session.shared"`. (org id: for group-owned sessions use `session.organization_id`; for user-owned it may be nil — `dispatch` no-ops on nil org, which is correct, OR resolve the user's org; for this pass nil-org user sessions simply don't fan out — note it.)
- [ ] **Step 2 — Billing.** After a subscription change commits, emit `:"subscription.updated"` with org/user + plan. **Credits.** At the low-balance signal (reuse the existing Credits PubSub choke point), emit `:"credits.low"`. Keep emission post-commit + best-effort.
- [ ] **Step 3 — tests:** with a subscribed org endpoint, `process_session` success → `assert_enqueued` a session.completed delivery; dismiss/address/visibility likewise; a billing change → subscription.updated. (Build minimal integration tests; reuse fixtures.) Confirm emission is post-commit (no read-before-commit). Run PASS.
- [ ] **Step 4 — commit:** `git add -A && git commit -m "feat(events): emit session/comment/share + billing/credits events at choke points (post-commit)"`

---

## Task 7: REST CRUD + OpenAPI

**Files:** `lib/perfect_paper_web/controllers/api/webhook_controller.ex` + `webhook_json.ex`; router; OpenAPI schema additions; test.

- [ ] **Step 1 — controller + routes** (authed `/api` scope): `GET/POST /api/webhooks`, `GET/PATCH/DELETE /api/webhooks/:id`, `POST /api/webhooks/:id/rotate-secret`, `GET /api/webhooks/:id/deliveries`. Build a `scope(conn)` like `HistoryController` and resolve the caller's org (from scope/current_user's org membership). Thin controller → `Webhooks.*`; `action_fallback FallbackController` (`:unauthorized`→403). Secret returned ONLY on create + rotate.
- [ ] **Step 2 — OpenAPI** schemas (`WebhookEndpoint`, `WebhookEndpointRequest`, `WebhookDelivery`) in `Api.Schemas`; annotate the controller actions (`operation`, tag "Webhooks", security bearer/apiKey) mirroring the HistoryController pattern.
- [ ] **Step 3 — tests:** controller — org-admin CRUD happy paths + non-admin 403; extend the Spec 7 coverage test's `expected` list with the `/api/webhooks*` paths. Run PASS.
- [ ] **Step 4 — commit:** `git add -A && git commit -m "feat(api): REST CRUD for webhooks (OpenAPI-documented, org-admin gated)"`

---

## Task 8: LiveView management page

**Files:** `lib/perfect_paper_web/live/webhooks_live.ex` + collocated `.html.heex`; router; test.

- [ ] **Step 1 — LiveView** `WebhooksLive`: org-admin gated via `on_mount` (build a scope; if not org admin, redirect/halt). Lists the org's endpoints (create form, delete), shows a delivery log per endpoint (status, attempts, response_status, timestamps), and a **redeliver** button → `Webhooks.redeliver`. Collocated template; **discrete test ids** (no multi-match selectors — per the LiveView quality bar); `paper` theme; reduced-motion for any animation; no emoji.
- [ ] **Step 2 — route** (authed live scope) `live "/webhooks", WebhooksLive`.
- [ ] **Step 3 — tests** `webhooks_live_test.exs`: admin sees endpoints + can create/delete; delivery log renders; redeliver triggers `assert_enqueued`; a non-admin is redirected. Use discrete ids. Run PASS.
- [ ] **Step 4 — commit:** `git add -A && git commit -m "feat(web): LiveView webhooks management (endpoints + delivery log + redeliver)"`

---

## Task 9: Update CLAUDE.md (policy)

**Files:** `CLAUDE.md`.

- [ ] **Step 1 — edit `CLAUDE.md`:**
  - In "Out of scope (this pass — do not build without asking)": REMOVE `webhooks` and `async/SSE/background jobs (return 501)` from the out-of-scope list (they are now in scope / built).
  - Add an adapter-table row: `| Outbound webhooks | Webhooks.Sender | Webhooks.Sender.Req | :webhook_sender |`.
  - Add a short subsection documenting: **Oban** is the job runner (queues incl. `webhooks`); the **`Events`** bus is the domain-event convention (contexts `Events.emit/2` POST-COMMIT, never inside a Multi); `Webhooks` owns durable delivery. Add `Events` and `Webhooks` to the Contexts list.
  - Keep edits surgical; match the doc's voice.
- [ ] **Step 2 — commit:** `git add CLAUDE.md && git commit -m "docs: lift no-async/no-webhooks rule; document Oban + Events bus + Webhooks"`

---

## Task 10: Pre-merge verification
- [ ] **Step 1:** `mix compile --force --warnings-as-errors` — clean.
- [ ] **Step 2:** `grep -rn "TODO(webhooks)" lib/` — confirm the deferred items (secret encryption, SSRF allow-listing) are greppable.
- [ ] **Step 3:** `mix precommit` — fully green (Oban `testing: :manual`; no real HTTP; all suites incl. webhooks/events/oban/liveview). `mix format`.
- [ ] **Step 4:** Update SOC 2 docs: add the `webhook_deliveries` log as CC7 audit evidence in `docs/compliance/soc2/evidence.md`/`controls.md` (1-2 lines). Commit.
- [ ] **Step 5:** `git add -A && git commit -m "chore(webhooks): precommit green; soc2 evidence note"`

---

## Self-review (authoring)
- **Spec coverage:** Oban (T1) ✓; Events bus envelope+emit/publish post-commit (T2) ✓; Webhooks schemas (T3) ✓; dispatch + signed (Stripe-style, ts-in-MAC) Oban delivery + Req/Stub adapter (T4) ✓; management API org-admin gated + rotate + redeliver (T5) ✓; emission at History/Billing/Credits choke points POST-COMMIT (T6) ✓; REST CRUD + OpenAPI (T7) ✓; LiveView mgmt + delivery log + redeliver (T8) ✓; CLAUDE.md policy edit + contexts list (T9) ✓; precommit + SOC2 evidence (T10) ✓.
- **At-least-once:** delivery row + Oban job in one transaction (T4). **Anti-replay:** ts inside the MAC (T4). **No read-before-commit:** emit only after commit (T2 doc + T6). **No real HTTP in tests:** Stub sender + Oban `:manual` (T1/T4).
- **Sequencing risk:** Task 2's `publish` references `Webhooks.dispatch` which lands in Task 4 — Task 2 defines `publish` WITHOUT that line (PubSub only) and Task 4 adds it. Stated in both tasks.
- **Org resolution for user-owned sessions:** nil-org events no-op in dispatch (documented in T6) — acceptable this pass; org-scoped webhooks fan out group/org-owned resources.
