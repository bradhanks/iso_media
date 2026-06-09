# Enterprise Billing (Spec 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seat-based **org-level** billing: a negotiated `Billing.Contract` (seats, per-seat price, per-seat credits, term) funds the org credit pool, is collected by **internal invoices** (NET terms), with soft seat overage (high-water mark), starvation-safe negative pool (bounded by a soft floor), and review consumption resolved by session ownership.

**Architecture:** Extend the **`Billing`** context (it owns the provider contract + per-user subscriptions). Seat count is driven by SCIM-provisioned **active membership** (3b) via a `member.*` event subscriber that bumps a high-water `peak_seats_used` in a single SQL statement. All money is integer cents; all pool mutations are atomic (`update_all(inc:)` / conditional `UPDATE`). Personal subscriptions are untouched; org-owned reviews draw from the org pool, personal reviews from personal credits.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto/PostgreSQL (`binary_id`), `Ecto.Multi`, Oban (already present), OpenApiSpex, the `Events` bus (Spec 8). No new deps. Spec: `docs/superpowers/specs/2026-06-04-enterprise-billing-design.md`.

---

## Conventions

- **Worktree:** Execute in `/Users/bradhanks/perfect_paper-billing` on branch `feat/enterprise-billing` (off `main`). Do NOT switch branches; **`git branch --show-current` must read `feat/enterprise-billing` before every commit** (the shared checkout gets commandeered by parallel sessions). Commit each task here; merge to `main` in the final task.
- **Test DB isolation:** `MIX_TEST_PARTITION=billing mix test ...` (a parallel session shares the Postgres test DB). Run only your task's tests while developing; full `mix precommit` is the pre-merge check.
- **`git add` EXPLICIT paths only** — never `-A`/`-u` blindly (untracked parallel-session files exist).
- **Architecture laws (CLAUDE.md):** one context = one public API + Repo boundary; schemas carry their own changesets; `@spec`/`@moduledoc`/`@doc` on all public funcs; multi-step writes use `Ecto.Multi`; side-effect events emitted **post-commit** via `Events.emit/2`.
- **Reference code:** `Billing.upgrade_plan/2` (Multi + provider + post-commit `Events.emit`), `Credits.AllowanceServer` (event subscriber GenServer pattern), `Organizations.allocate_credits_to_member/3` (FOR UPDATE row-lock pool discipline), `PerfectPaperWeb.Api.SsoController` / `Scim` controllers (org-admin-gated REST + OpenAPI), `SsoLive`/`ScimLive` (org-admin LiveView), `PerfectPaperWeb.UserAuth.admin_emails/0` + `on_mount(:require_admin)` (platform-admin gate).

## Money & invariants (apply everywhere)
- Money is **integer cents**; never floats. `amount_cents`/`funded_credits` are recomputed server-side from `seats × price` / `× per_seat_credits` — never trusted from a request.
- All pool reads-then-writes are atomic: funding/clawback use `Repo.update_all(…, inc: [credit_pool: ±n])`; consumption uses a conditional `UPDATE` or the existing FOR-UPDATE lock. `peak_seats_used` bump is a single SQL statement.
- "Active contract" is **date-aware**: `status == :active` AND `term_start <= today <= term_end`.

## File structure
```
priv/repo/migrations/20260604*_*.exs              # T1: org_contracts (+partial unique active), invoices
lib/perfect_paper/billing/contract.ex             # T1: schema + changesets
lib/perfect_paper/billing/invoice.ex              # T1: schema + changesets
lib/perfect_paper/events/event.ex                 # T1: + 4 event types
lib/perfect_paper/billing.ex                      # T2,T4,T5: contract + invoice context fns
lib/perfect_paper/billing/seat_tracker_server.ex  # T3: member.* subscriber → peak bump
lib/perfect_paper/organizations.ex                # T3,T5: active_member_count, fund_pool, charge_pool
lib/perfect_paper/application.ex                  # T3: supervise SeatTrackerServer
lib/perfect_paper/history.ex                      # T5: route review charge by session ownership
lib/perfect_paper_web/controllers/api/billing_controller.ex (+ json)  # T6
lib/perfect_paper_web/plugs/require_platform_admin.ex                 # T6
lib/perfect_paper_web/live/org_billing_live.ex (+ .heex)             # T7 org-admin
lib/perfect_paper_web/live/admin_live/billing.ex (+ .heex)           # T7 internal
lib/perfect_paper_web/router.ex                   # T6,T7 routes
lib/perfect_paper_web/api/schemas.ex              # T6 OpenAPI schemas
```

---

## Task 1: Migrations + Contract/Invoice schemas + event types

**Files:** Create `priv/repo/migrations/20260604200001_create_org_contracts.exs`, `20260604200002_create_invoices.exs`, `lib/perfect_paper/billing/contract.ex`, `lib/perfect_paper/billing/invoice.ex`. Modify `lib/perfect_paper/events/event.ex`. Test `test/perfect_paper/billing/contract_test.exs`, `test/perfect_paper/billing/invoice_test.exs`.

- [ ] **Step 1: Migrations**

`20260604200001_create_org_contracts.exs`:
```elixir
defmodule PerfectPaper.Repo.Migrations.CreateOrgContracts do
  use Ecto.Migration

  def change do
    create table(:org_contracts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :seats, :integer, null: false
      add :price_per_seat_cents, :integer, null: false, default: 0
      add :per_seat_credits, :integer, null: false, default: 0
      add :interval, :string, null: false, default: "monthly"
      add :status, :string, null: false, default: "draft"
      add :term_start, :date
      add :term_end, :date
      add :po_number, :string
      add :net_terms_days, :integer, null: false, default: 30
      add :peak_seats_used, :integer, null: false, default: 0
      add :last_funded_period, :date
      add :created_by, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:org_contracts, [:organization_id])
    # At most one ACTIVE contract per org (draft/expired/canceled unbounded).
    create unique_index(:org_contracts, [:organization_id],
             where: "status = 'active'",
             name: :unique_active_contract_per_org
           )
  end
end
```

`20260604200002_create_invoices.exs`:
```elixir
defmodule PerfectPaper.Repo.Migrations.CreateInvoices do
  use Ecto.Migration

  def change do
    create table(:invoices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :contract_id, references(:org_contracts, type: :binary_id, on_delete: :delete_all), null: false
      add :number, :string, null: false
      add :period_start, :date, null: false
      add :period_end, :date, null: false
      add :seats_billed, :integer, null: false
      add :seat_overage, :integer, null: false, default: 0
      add :amount_cents, :integer, null: false
      add :funded_credits, :integer, null: false, default: 0
      add :status, :string, null: false, default: "issued"
      add :issued_at, :utc_datetime, null: false
      add :due_at, :utc_datetime, null: false
      add :paid_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:invoices, [:number])
    create index(:invoices, [:organization_id])
    create index(:invoices, [:status])
  end
end
```

- [ ] **Step 2: Run migrations** — `MIX_TEST_PARTITION=billing mix ecto.migrate` and `MIX_TEST_PARTITION=billing MIX_ENV=test mix ecto.migrate`. Expected: clean.

- [ ] **Step 3: `Billing.Contract` schema**

`lib/perfect_paper/billing/contract.ex`:
```elixir
defmodule PerfectPaper.Billing.Contract do
  @moduledoc """
  An enterprise org's seat-based billing contract. Negotiated (sales-arranged):
  `seats`, `price_per_seat_cents`, and `per_seat_credits` are all **per billing
  period** (the `interval`), so a single cadence drives invoicing + pool funding.
  At most one `:active` contract per org (DB partial unique index).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "org_contracts" do
    field :organization_id, :binary_id
    field :seats, :integer
    field :price_per_seat_cents, :integer, default: 0
    field :per_seat_credits, :integer, default: 0
    field :interval, Ecto.Enum, values: [:monthly, :annual], default: :monthly
    field :status, Ecto.Enum, values: [:draft, :active, :expired, :canceled], default: :draft
    field :term_start, :date
    field :term_end, :date
    field :po_number, :string
    field :net_terms_days, :integer, default: 30
    field :peak_seats_used, :integer, default: 0
    field :last_funded_period, :date
    field :created_by, :binary_id
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating/editing a draft contract (tenant-safe fields only)."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(contract, attrs) do
    contract
    |> cast(attrs, [
      :organization_id, :seats, :price_per_seat_cents, :per_seat_credits,
      :interval, :term_start, :term_end, :po_number, :net_terms_days, :created_by
    ])
    |> validate_required([:organization_id, :seats, :term_start, :term_end])
    |> validate_number(:seats, greater_than: 0)
    |> validate_number(:price_per_seat_cents, greater_than_or_equal_to: 0)
    |> validate_number(:per_seat_credits, greater_than_or_equal_to: 0)
  end

  @doc "Changeset for a privileged status transition (never cast from request bodies)."
  @spec status_changeset(t(), atom()) :: Ecto.Changeset.t()
  def status_changeset(contract, status) when status in [:draft, :active, :expired, :canceled] do
    change(contract, status: status)
    |> unique_constraint(:organization_id, name: :unique_active_contract_per_org)
  end
end
```

- [ ] **Step 4: `Billing.Invoice` schema**

`lib/perfect_paper/billing/invoice.ex`:
```elixir
defmodule PerfectPaper.Billing.Invoice do
  @moduledoc """
  An internal AR invoice for a contract period. `funded_credits` records the
  exact credits this invoice added to the org pool, so a void claws back the
  precise amount. `number` is non-enumerable (`INV-YYYYMM-<base32>`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invoices" do
    field :organization_id, :binary_id
    field :contract_id, :binary_id
    field :number, :string
    field :period_start, :date
    field :period_end, :date
    field :seats_billed, :integer
    field :seat_overage, :integer, default: 0
    field :amount_cents, :integer
    field :funded_credits, :integer, default: 0
    field :status, Ecto.Enum, values: [:issued, :paid, :overdue, :void], default: :issued
    field :issued_at, :utc_datetime
    field :due_at, :utc_datetime
    field :paid_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a freshly issued invoice (all amounts server-computed)."
  @spec issue_changeset(t(), map()) :: Ecto.Changeset.t()
  def issue_changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :organization_id, :contract_id, :number, :period_start, :period_end,
      :seats_billed, :seat_overage, :amount_cents, :funded_credits,
      :status, :issued_at, :due_at
    ])
    |> validate_required([
      :organization_id, :contract_id, :number, :period_start, :period_end,
      :seats_billed, :amount_cents, :issued_at, :due_at
    ])
    |> unique_constraint(:number)
  end

  @doc "Changeset for a status transition (:paid sets paid_at; :void/:overdue do not)."
  @spec status_changeset(t(), :paid | :void | :overdue, DateTime.t() | nil) :: Ecto.Changeset.t()
  def status_changeset(invoice, :paid, paid_at), do: change(invoice, status: :paid, paid_at: paid_at)
  def status_changeset(invoice, status, _), do: change(invoice, status: status)
end
```

- [ ] **Step 5: Register event types** — in `lib/perfect_paper/events/event.ex`, append to `@types`: `contract.created contract.activated invoice.issued invoice.paid`. (Emitting an unregistered type fails the `Ecto.Enum` cast — register before emitting.)

- [ ] **Step 6: Failing schema tests**

`test/perfect_paper/billing/contract_test.exs`:
```elixir
defmodule PerfectPaper.Billing.ContractTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Billing.Contract

  test "create_changeset requires org, seats, term dates and positive seats" do
    cs = Contract.create_changeset(%Contract{}, %{organization_id: Ecto.UUID.generate(), seats: 0, term_start: ~D[2026-01-01], term_end: ~D[2026-12-31]})
    refute cs.valid?
    assert %{seats: _} = errors_on(cs)
  end

  test "create_changeset accepts a valid draft" do
    cs = Contract.create_changeset(%Contract{}, %{organization_id: Ecto.UUID.generate(), seats: 10, price_per_seat_cents: 5000, per_seat_credits: 100, term_start: ~D[2026-01-01], term_end: ~D[2026-12-31]})
    assert cs.valid?
  end
end
```

`test/perfect_paper/billing/invoice_test.exs`:
```elixir
defmodule PerfectPaper.Billing.InvoiceTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Billing.Invoice

  test "issue_changeset requires the core billed fields" do
    cs = Invoice.issue_changeset(%Invoice{}, %{})
    refute cs.valid?
  end
end
```

- [ ] **Step 7: Run** — `MIX_TEST_PARTITION=billing mix test test/perfect_paper/billing/contract_test.exs test/perfect_paper/billing/invoice_test.exs` → PASS. `MIX_TEST_PARTITION=billing mix compile --warnings-as-errors` → clean.

- [ ] **Step 8: Commit**
```bash
git add priv/repo/migrations/20260604200001_create_org_contracts.exs priv/repo/migrations/20260604200002_create_invoices.exs lib/perfect_paper/billing/contract.ex lib/perfect_paper/billing/invoice.ex lib/perfect_paper/events/event.ex test/perfect_paper/billing/contract_test.exs test/perfect_paper/billing/invoice_test.exs
git commit -m "feat(billing): org_contracts + invoices schemas (+partial unique active) + contract/invoice event types"
```

---

## Task 2: Contract context — create / cancel / date-aware active / swap

**Files:** Modify `lib/perfect_paper/billing.ex`. Test `test/perfect_paper/billing/contract_context_test.exs`.

Add to `Billing` (it already aliases `Repo`, `Events`, `Subscription`; add `alias PerfectPaper.Billing.{Contract, Invoice}` and `import Ecto.Query`). `activate_contract` flips status only this task; first-invoice + funding is wired in Task 4.

- [ ] **Step 1: Failing tests** — `test/perfect_paper/billing/contract_context_test.exs`:
```elixir
defmodule PerfectPaper.Billing.ContractContextTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Billing
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    owner = user_fixture()
    org = organization_fixture(owner)
    %{org: org, owner: owner}
  end

  defp draft(org, owner, attrs \\ %{}) do
    base = %{organization_id: org.id, seats: 10, price_per_seat_cents: 5000, per_seat_credits: 100,
             term_start: Date.utc_today(), term_end: Date.add(Date.utc_today(), 365), created_by: owner.id}
    {:ok, c} = Billing.create_contract(org, Map.merge(base, attrs))
    c
  end

  test "create_contract inserts a draft", %{org: org, owner: owner} do
    c = draft(org, owner)
    assert c.status == :draft
  end

  test "activate_contract sets active; a second active is refused", %{org: org, owner: owner} do
    c1 = draft(org, owner)
    {:ok, _} = Billing.activate_contract(c1)
    c2 = draft(org, owner)
    assert {:error, :active_contract_exists} = Billing.activate_contract(c2)
  end

  test "has_active_contract? is date-aware", %{org: org, owner: owner} do
    c = draft(org, owner)
    {:ok, _} = Billing.activate_contract(c)
    assert Billing.has_active_contract?(org.id)

    expired = draft(org, owner, %{term_start: ~D[2020-01-01], term_end: ~D[2020-12-31]})
    {:ok, _} = Billing.cancel_contract(Repo.get!(PerfectPaper.Billing.Contract, c.id))
    {:ok, _} = Billing.activate_contract(expired)
    refute Billing.has_active_contract?(org.id)
  end

  test "swap_active_contract has no zero-active window", %{org: org, owner: owner} do
    a = draft(org, owner)
    {:ok, a} = Billing.activate_contract(a)
    b = draft(org, owner)
    assert {:ok, _} = Billing.swap_active_contract(org.id, a.id, b.id)
    assert Billing.has_active_contract?(org.id)
  end
end
```

- [ ] **Step 2: Run → FAIL** (functions undefined).

- [ ] **Step 3: Implement**
```elixir
@doc "Creates a draft enterprise contract. Internal/platform-admin gating is enforced at the web layer."
@spec create_contract(Organizations.Organization.t(), map()) :: {:ok, Contract.t()} | {:error, Ecto.Changeset.t()}
def create_contract(%{id: org_id}, attrs) do
  attrs = Map.put(attrs, :organization_id, org_id)
  with {:ok, contract} <- %Contract{} |> Contract.create_changeset(attrs) |> Repo.insert() do
    Events.emit(:"contract.created", %{organization_id: org_id, actor_id: attrs[:created_by],
      resource: %{type: :contract, id: contract.id}, data: %{seats: contract.seats}})
    {:ok, contract}
  end
end

@doc "Activates a draft contract. Refuses a second active per org (partial unique index). (First invoice + funding wired in issue_invoice — Task 4.)"
@spec activate_contract(Contract.t()) :: {:ok, Contract.t()} | {:error, :active_contract_exists | term()}
def activate_contract(%Contract{} = contract) do
  changeset = Contract.status_changeset(%{contract | term_start: contract.term_start || Date.utc_today()}, :active)
  case Repo.update(changeset) do
    {:ok, c} ->
      Events.emit(:"contract.activated", %{organization_id: c.organization_id, actor_id: nil,
        resource: %{type: :contract, id: c.id}, data: %{seats: c.seats}})
      {:ok, c}
    {:error, %Ecto.Changeset{errors: errors}} ->
      if Keyword.has_key?(errors, :organization_id), do: {:error, :active_contract_exists}, else: {:error, :invalid}
  end
end

@doc "Cancels a contract (stops future funding; pool balance unchanged)."
@spec cancel_contract(Contract.t()) :: {:ok, Contract.t()} | {:error, term()}
def cancel_contract(%Contract{} = contract), do: Repo.update(Contract.status_changeset(contract, :canceled))

@doc "Atomic renewal: expire the old active contract and activate the new draft in one transaction (no zero-active window)."
@spec swap_active_contract(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Contract.t()} | {:error, term()}
def swap_active_contract(org_id, old_id, new_id) do
  Repo.transact(fn ->
    with {1, _} <- Repo.update_all(from(c in Contract, where: c.id == ^old_id and c.organization_id == ^org_id and c.status == :active), set: [status: :expired]),
         new <- Repo.get_by!(Contract, id: new_id, organization_id: org_id),
         {:ok, activated} <- Repo.update(Contract.status_changeset(%{new | term_start: new.term_start || Date.utc_today()}, :active)) do
      {:ok, activated}
    else
      {0, _} -> {:error, :no_active_contract}
      other -> other
    end
  end)
end

@doc "True iff the org has a contract that is `:active` AND whose term covers today (date-aware — no cron dependency)."
@spec has_active_contract?(Ecto.UUID.t()) :: boolean()
def has_active_contract?(org_id) do
  today = Date.utc_today()
  Repo.exists?(from c in Contract,
    where: c.organization_id == ^org_id and c.status == :active and c.term_start <= ^today and c.term_end >= ^today)
end

@doc "Returns the org's date-aware active contract, or nil."
@spec active_contract(Ecto.UUID.t()) :: Contract.t() | nil
def active_contract(org_id) do
  today = Date.utc_today()
  Repo.one(from c in Contract,
    where: c.organization_id == ^org_id and c.status == :active and c.term_start <= ^today and c.term_end >= ^today, limit: 1)
end
```

- [ ] **Step 4: Run → PASS.** Commit:
```bash
git add lib/perfect_paper/billing.ex test/perfect_paper/billing/contract_context_test.exs
git commit -m "feat(billing): contract create/activate(single-active)/cancel/swap + date-aware has_active_contract?"
```

---

## Task 3: Seat counting + high-water peak server + atomic fund_pool

**Files:** Modify `lib/perfect_paper/organizations.ex` (`active_member_count/1`, `fund_pool/2`). Modify `lib/perfect_paper/billing.ex` (`bump_peak_seats_for_event/1`). Create `lib/perfect_paper/billing/seat_tracker_server.ex`. Modify `lib/perfect_paper/application.ex`. Test `test/perfect_paper/billing/seat_tracking_test.exs`.

- [ ] **Step 1: Failing tests** — `test/perfect_paper/billing/seat_tracking_test.exs`:
```elixir
defmodule PerfectPaper.Billing.SeatTrackingTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Billing, Organizations}
  alias PerfectPaper.Billing.Contract
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    owner = user_fixture()
    org = organization_fixture(owner)
    {:ok, c} = Billing.create_contract(org, %{organization_id: org.id, seats: 5, per_seat_credits: 10,
      price_per_seat_cents: 1000, term_start: Date.utc_today(), term_end: Date.add(Date.utc_today(), 365)})
    {:ok, c} = Billing.activate_contract(c)
    %{org: org, contract: c}
  end

  test "active_member_count counts only :active memberships", %{org: org} do
    {:ok, _} = Organizations.add_member(org, user_fixture(), :member)
    {:ok, m2} = Organizations.add_member(org, user_fixture(), :member)
    assert Organizations.active_member_count(org.id) == 2
    {:ok, _} = Organizations.deactivate_membership(org, m2.user_id)
    assert Organizations.active_member_count(org.id) == 1
  end

  test "fund_pool atomically increments", %{org: org} do
    :ok = Organizations.fund_pool(org.id, 250)
    assert Organizations.credit_pool_status(org.id).pool == 250
    :ok = Organizations.fund_pool(org.id, 250)
    assert Organizations.credit_pool_status(org.id).pool == 500
  end

  test "bump_peak_seats_for_event raises peak to current active count and never lowers it", %{org: org, contract: c} do
    u1 = user_fixture(); u2 = user_fixture()
    {:ok, _} = Organizations.add_member(org, u1, :member)
    {:ok, m2} = Organizations.add_member(org, u2, :member)
    evt = %PerfectPaper.Events.Event{type: :"member.provisioned", organization_id: org.id, data: %{}}
    Billing.bump_peak_seats_for_event(evt)
    assert PerfectPaper.Repo.get!(Contract, c.id).peak_seats_used == 2
    # deactivate one then bump again — peak stays at the high-water 2
    {:ok, _} = Organizations.deactivate_membership(org, m2.user_id)
    Billing.bump_peak_seats_for_event(evt)
    assert PerfectPaper.Repo.get!(Contract, c.id).peak_seats_used == 2
  end
end
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement `Organizations` primitives** (add to `lib/perfect_paper/organizations.ex`):
```elixir
@doc "Count of `:active` memberships in the org (billable seats)."
@spec active_member_count(Ecto.UUID.t()) :: non_neg_integer()
def active_member_count(org_id) do
  Repo.one(from m in Membership, where: m.organization_id == ^org_id and m.status == :active, select: count(m.id))
end

@doc "Atomically adds `amount` credits to the org pool (no read-modify-write). Bypasses the pool changeset by design — funding is privileged + may push a contract pool above any cap."
@spec fund_pool(Ecto.UUID.t(), integer()) :: :ok
def fund_pool(org_id, amount) do
  Repo.update_all(from(o in Organization, where: o.id == ^org_id), inc: [credit_pool: amount])
  :ok
end
```

- [ ] **Step 4: Implement `Billing.bump_peak_seats_for_event/1`** (single SQL — count + GREATEST in one statement; never SELECT-then-UPDATE):
```elixir
@doc """
Raises the active contract's `peak_seats_used` high-water mark to the org's
current `:active` member count, computed inside a single atomic SQL statement so
a concurrent bulk SCIM import cannot under-report the peak. Ignores orgs without
an active contract. Called by `SeatTrackerServer` on member activation events.
"""
@spec bump_peak_seats_for_event(Events.Event.t()) :: :ok
def bump_peak_seats_for_event(%Events.Event{organization_id: org_id})
    when is_binary(org_id) do
  Repo.update_all(
    from(c in Contract, where: c.organization_id == ^org_id and c.status == :active,
      update: [set: [peak_seats_used:
        fragment("GREATEST(?, (SELECT count(*) FROM memberships WHERE organization_id = ? AND status = 'active'))",
          c.peak_seats_used, ^org_id)]]),
    []
  )
  :ok
end

def bump_peak_seats_for_event(_), do: :ok
```

- [ ] **Step 5: `SeatTrackerServer`** — `lib/perfect_paper/billing/seat_tracker_server.ex` (mirror `Credits.AllowanceServer`):
```elixir
defmodule PerfectPaper.Billing.SeatTrackerServer do
  @moduledoc """
  Subscribes to `member.provisioned` and `member.reactivated` (SCIM/Spec 3b) and
  raises the org's active-contract `peak_seats_used` high-water mark. Decoupled:
  Organizations just announces activations via `Events.emit/2`. Errors are logged,
  never raised, so one bad event can't take the server down.
  """
  use GenServer
  require Logger
  alias PerfectPaper.{Billing, Events}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Events.subscribe(:"member.provisioned")
    Events.subscribe(:"member.reactivated")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:event, %Events.Event{} = event}, state) do
    try do
      Billing.bump_peak_seats_for_event(event)
    rescue
      error -> Logger.error("SeatTrackerServer failed on #{inspect(event.type)}: #{inspect(error)}")
    end
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

- [ ] **Step 6: Supervise it** — in `lib/perfect_paper/application.ex`, add `PerfectPaper.Billing.SeatTrackerServer` to the children list next to `PerfectPaper.Credits.AllowanceServer`.

- [ ] **Step 7: Run → PASS.** `mix compile --warnings-as-errors` clean. Commit:
```bash
git add lib/perfect_paper/organizations.ex lib/perfect_paper/billing.ex lib/perfect_paper/billing/seat_tracker_server.ex lib/perfect_paper/application.ex test/perfect_paper/billing/seat_tracking_test.exs
git commit -m "feat(billing): active_member_count + atomic fund_pool + single-SQL high-water peak via member.* subscriber"
```

---

## Task 4: Invoicing — issue (fund+reset), mark-paid, void (clawback), numbering

**Files:** Modify `lib/perfect_paper/billing.ex`. Test `test/perfect_paper/billing/invoicing_test.exs`.

- [ ] **Step 1: Failing tests** — `test/perfect_paper/billing/invoicing_test.exs`:
```elixir
defmodule PerfectPaper.Billing.InvoicingTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Billing, Organizations}
  alias PerfectPaper.Billing.{Contract, Invoice}
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    owner = user_fixture(); org = organization_fixture(owner)
    {:ok, c} = Billing.create_contract(org, %{organization_id: org.id, seats: 10, price_per_seat_cents: 5000,
      per_seat_credits: 100, term_start: Date.utc_today(), term_end: Date.add(Date.utc_today(), 365)})
    {:ok, c} = Billing.activate_contract(c)
    # simulate a peak of 12 (2 over)
    PerfectPaper.Repo.update_all(from(x in Contract, where: x.id == ^c.id), set: [peak_seats_used: 12])
    %{org: org, contract: PerfectPaper.Repo.get!(Contract, c.id)}
  end

  test "issue_invoice bills seats+overage, funds the pool by funded_credits, resets peak", %{org: org, contract: c} do
    {:ok, inv} = Billing.issue_invoice(c, Date.utc_today())
    assert inv.seats_billed == 10 and inv.seat_overage == 2
    assert inv.amount_cents == 12 * 5000
    assert inv.funded_credits == 12 * 100
    assert Organizations.credit_pool_status(org.id).pool == 12 * 100
    assert PerfectPaper.Repo.get!(Contract, c.id).peak_seats_used == Organizations.active_member_count(org.id)
    assert inv.number =~ ~r/^INV-\d{6}-[A-Z2-7]{8}$/
  end

  test "mark_invoice_paid sets :paid + paid_at", %{contract: c} do
    {:ok, inv} = Billing.issue_invoice(c, Date.utc_today())
    {:ok, paid} = Billing.mark_invoice_paid(inv)
    assert paid.status == :paid and paid.paid_at
  end

  test "void_invoice claws back exactly funded_credits", %{org: org, contract: c} do
    {:ok, inv} = Billing.issue_invoice(c, Date.utc_today())
    funded = Organizations.credit_pool_status(org.id).pool
    {:ok, voided} = Billing.void_invoice(inv)
    assert voided.status == :void
    assert Organizations.credit_pool_status(org.id).pool == funded - inv.funded_credits
  end
end
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** (in `lib/perfect_paper/billing.ex`; needs `alias PerfectPaper.Organizations`):
```elixir
@doc """
Issues an invoice for the contract's current period and (atomically) funds the
pool by `funded_credits` and resets the high-water mark. `billed_seats =
seats + max(0, peak_seats_used − seats)`.
"""
@spec issue_invoice(Contract.t(), Date.t()) :: {:ok, Invoice.t()} | {:error, term()}
def issue_invoice(%Contract{} = contract, period_start) do
  overage = max(0, contract.peak_seats_used - contract.seats)
  billed = contract.seats + overage
  amount = billed * contract.price_per_seat_cents
  funded = billed * contract.per_seat_credits
  period_end = period_end_for(contract.interval, period_start)
  now = DateTime.utc_now() |> DateTime.truncate(:second)

  result =
    Repo.transact(fn ->
      with {:ok, invoice} <- insert_invoice_with_unique_number(%{
             organization_id: contract.organization_id, contract_id: contract.id,
             period_start: period_start, period_end: period_end,
             seats_billed: contract.seats, seat_overage: overage,
             amount_cents: amount, funded_credits: funded, status: :issued,
             issued_at: now, due_at: DateTime.add(now, contract.net_terms_days * 86_400)
           }),
           :ok <- Organizations.fund_pool(contract.organization_id, funded),
           {_, _} <- Repo.update_all(from(c in Contract, where: c.id == ^contract.id),
                       set: [peak_seats_used: Organizations.active_member_count(contract.organization_id),
                             last_funded_period: period_start]) do
        {:ok, invoice}
      end
    end)

  with {:ok, invoice} <- result do
    Events.emit(:"invoice.issued", %{organization_id: contract.organization_id, actor_id: nil,
      resource: %{type: :invoice, id: invoice.id}, data: %{number: invoice.number, amount_cents: amount}})
    {:ok, invoice}
  end
end

@doc "Marks an invoice paid (internal/platform-admin)."
@spec mark_invoice_paid(Invoice.t()) :: {:ok, Invoice.t()} | {:error, term()}
def mark_invoice_paid(%Invoice{} = invoice) do
  now = DateTime.utc_now() |> DateTime.truncate(:second)
  with {:ok, paid} <- Repo.update(Invoice.status_changeset(invoice, :paid, now)) do
    Events.emit(:"invoice.paid", %{organization_id: paid.organization_id, actor_id: nil,
      resource: %{type: :invoice, id: paid.id}, data: %{number: paid.number}})
    {:ok, paid}
  end
end

@doc "Voids an invoice AND claws back exactly its `funded_credits` from the pool (closes the issue→void free-credit loophole; pool may go deeply negative)."
@spec void_invoice(Invoice.t()) :: {:ok, Invoice.t()} | {:error, term()}
def void_invoice(%Invoice{} = invoice) do
  Repo.transact(fn ->
    with {:ok, voided} <- Repo.update(Invoice.status_changeset(invoice, :void, nil)),
         :ok <- Organizations.fund_pool(invoice.organization_id, -invoice.funded_credits) do
      {:ok, voided}
    end
  end)
end

# Period end for a billing interval.
defp period_end_for(:monthly, start), do: Date.add(Date.add(start, 30), 0)
defp period_end_for(:annual, start), do: Date.add(start, 365)

# Inserts an invoice, regenerating a non-enumerable INV-YYYYMM-<base32> number on collision.
defp insert_invoice_with_unique_number(attrs, attempts \\ 0) do
  number = invoice_number(attrs.period_start)
  case %Invoice{} |> Invoice.issue_changeset(Map.put(attrs, :number, number)) |> Repo.insert() do
    {:ok, inv} -> {:ok, inv}
    {:error, %Ecto.Changeset{errors: errs}} = err ->
      if Keyword.has_key?(errs, :number) and attempts < 5, do: insert_invoice_with_unique_number(attrs, attempts + 1), else: err
  end
end

defp invoice_number(date) do
  ym = Calendar.strftime(date, "%Y%m")
  slug = :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false) |> binary_part(0, 8)
  "INV-#{ym}-#{slug}"
end
```

- [ ] **Step 4: Wire `activate_contract` to issue the first invoice** — replace the `{:ok, c} ->` branch of `activate_contract` (Task 2) so after activation it calls `issue_invoice(c, Date.utc_today())` and returns the contract (log/ignore invoice errors so activation still succeeds — or wrap in the same transaction; keep it simple: `_ = issue_invoice(c, c.term_start || Date.utc_today())`). Add a test in `contract_context_test.exs`: after `activate_contract`, `Billing.list_invoices(org.id)` has one invoice and the pool is funded.

- [ ] **Step 5: Add read helpers** used by the web layer + the activate test:
```elixir
@spec get_contract(Ecto.UUID.t()) :: Contract.t() | nil
def get_contract(org_id), do: active_contract(org_id) || Repo.one(from c in Contract, where: c.organization_id == ^org_id, order_by: [desc: c.inserted_at], limit: 1)

@spec list_invoices(Ecto.UUID.t()) :: [Invoice.t()]
def list_invoices(org_id), do: Repo.all(from i in Invoice, where: i.organization_id == ^org_id, order_by: [desc: i.issued_at])

@spec get_invoice(Ecto.UUID.t(), Ecto.UUID.t()) :: Invoice.t() | nil
def get_invoice(org_id, id), do: Repo.get_by(Invoice, id: id, organization_id: org_id)
```

- [ ] **Step 6: Run → PASS.** Commit:
```bash
git add lib/perfect_paper/billing.ex test/perfect_paper/billing/invoicing_test.exs test/perfect_paper/billing/contract_context_test.exs
git commit -m "feat(billing): issue_invoice (fund pool + reset peak, INV-YYYYMM-<rand>), mark-paid, void with credit clawback; activate issues first invoice"
```

---

## Task 5: Contract-aware pool consumption + route review charge by session ownership

**Files:** Modify `lib/perfect_paper/organizations.ex` (`charge_pool/2`). Modify `lib/perfect_paper/history.ex` (`charge_for_level/2`). Test `test/perfect_paper/billing/consumption_test.exs`.

The org pool is consumed when a review runs on an **org-owned** session. Today `History.charge_for_level(session.owner_id, level)` always charges personal credits. We route by ownership: org-owned (sessions carry `organization_id` + `owner_type == :group`) → `Organizations.charge_pool`; personal → existing `Credits.charge_for_proofreading`.

- [ ] **Step 1: Failing tests** — `test/perfect_paper/billing/consumption_test.exs`:
```elixir
defmodule PerfectPaper.Billing.ConsumptionTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Billing, Organizations}
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    owner = user_fixture(); org = organization_fixture(owner)
    {:ok, c} = Billing.create_contract(org, %{organization_id: org.id, seats: 2, per_seat_credits: 1,
      price_per_seat_cents: 1000, term_start: Date.utc_today(), term_end: Date.add(Date.utc_today(), 365)})
    {:ok, _} = Billing.activate_contract(c)   # funds pool with 2 * 1 = 2 (active_member_count 0 → peak 0 → billed = max(2,0)=2)
    %{org: org}
  end

  test "charge_pool draws from a positive pool without a contract query (fast path)", %{org: org} do
    assert :ok = Organizations.charge_pool(org.id, 1)
    assert Organizations.credit_pool_status(org.id).pool == 1
  end

  test "under an active contract the pool may go negative down to the soft floor", %{org: org} do
    # floor = -(seats 2 * per_seat_credits 1 * 2) = -4 ; pool starts at 2
    assert :ok = Organizations.charge_pool(org.id, 5)   # 2 - 5 = -3  (>= -4) allowed
    assert Organizations.credit_pool_status(org.id).pool == -3
    assert {:error, :insufficient_credits} = Organizations.charge_pool(org.id, 3)  # -3 - 3 = -6 < -4 refused
  end

  test "a no-contract org refuses to go negative", %{} do
    org2 = organization_fixture(user_fixture())
    :ok = Organizations.fund_pool(org2.id, 1)
    assert {:error, :insufficient_credits} = Organizations.charge_pool(org2.id, 2)
  end
end
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement `Organizations.charge_pool/2`** (hot path: fast conditional decrement; slow path only when it would go negative — queries `Billing.has_active_contract?` + the soft floor):
```elixir
@doc """
Charges `amount` credits to the org pool for an org-owned review. Fast path: an
atomic conditional decrement when the pool stays non-negative (no contract
query). Slow path (would go negative): allowed only under a date-aware active
contract AND while staying at/above the soft floor `−(seats × per_seat_credits × 2)`.
"""
@spec charge_pool(Ecto.UUID.t(), pos_integer()) :: :ok | {:error, :insufficient_credits}
def charge_pool(org_id, amount) when amount > 0 do
  {fast, _} =
    Repo.update_all(
      from(o in Organization, where: o.id == ^org_id and o.credit_pool >= ^amount),
      inc: [credit_pool: -amount]
    )

  if fast == 1 do
    :ok
  else
    case PerfectPaper.Billing.contract_floor(org_id) do
      {:ok, floor} ->
        {slow, _} =
          Repo.update_all(
            from(o in Organization, where: o.id == ^org_id and o.credit_pool - ^amount >= ^floor),
            inc: [credit_pool: -amount]
          )

        if slow == 1, do: :ok, else: {:error, :insufficient_credits}

      :none ->
        {:error, :insufficient_credits}
    end
  end
end
```
And in `Billing` (date-aware floor; `:none` when no active contract):
```elixir
@doc "The negative-pool soft floor for an org: `−(seats × per_seat_credits × 2)` under an active contract, else `:none`."
@spec contract_floor(Ecto.UUID.t()) :: {:ok, integer()} | :none
def contract_floor(org_id) do
  case active_contract(org_id) do
    %Contract{seats: s, per_seat_credits: c} -> {:ok, -(s * c * 2)}
    nil -> :none
  end
end
```

- [ ] **Step 4: Route the review charge by ownership** — in `lib/perfect_paper/history.ex`, the review Multi calls `charge_for_level(session.owner_id, level)`. Change the call site to pass the whole `session` and branch on ownership. Replace `charge_for_level/2`:
```elixir
# org-owned (group session under an org) → draw the org pool; personal → personal credits.
defp charge_for_level(%{owner_type: :group, organization_id: org_id}, :full) when is_binary(org_id),
  do: with(:ok <- PerfectPaper.Organizations.charge_pool(org_id, 1), do: {:ok, :charged})
defp charge_for_level(%{owner_type: :group, organization_id: org_id}, :preview) when is_binary(org_id),
  do: with(:ok <- PerfectPaper.Organizations.charge_pool(org_id, 1), do: {:ok, :charged})
defp charge_for_level(%{owner_id: user_id}, :full), do: Credits.charge_for_proofreading(user_id)
defp charge_for_level(%{owner_id: user_id}, :preview), do: Credits.charge_for_preview(user_id)
```
Update the Multi step to pass `session` instead of `session.owner_id`: `Multi.run(:charge, fn _repo, _changes -> charge_for_level(session, level) end)`. (Read the surrounding `History` review function first; keep its return-shape contract — `{:ok, _}`/`{:error, _}`.)

- [ ] **Step 5: Run → PASS** (`consumption_test.exs` + the existing `test/perfect_paper/history_test.exs` to confirm personal charging still works). Commit:
```bash
git add lib/perfect_paper/organizations.ex lib/perfect_paper/billing.ex lib/perfect_paper/history.ex test/perfect_paper/billing/consumption_test.exs
git commit -m "feat(billing): contract-aware charge_pool (fast path + negative soft floor) + route review charge by session ownership"
```

---

## Task 6: REST — org-admin view + platform-admin manage (OpenAPI)

**Files:** Create `lib/perfect_paper_web/plugs/require_platform_admin.ex`, `lib/perfect_paper_web/controllers/api/billing_controller.ex` (+ `billing_json.ex`). Modify `lib/perfect_paper_web/router.ex`, `lib/perfect_paper_web/api/schemas.ex`. Test `test/perfect_paper_web/controllers/api/billing_controller_test.exs`.

Reference `Scim`/`Sso` controllers for the org-admin posture (`Organizations.admin?` → 403, `get_organization` → 404, `action_fallback`). Platform-admin = `current_user.email in PerfectPaperWeb.UserAuth.admin_emails()`.

- [ ] **Step 1: `RequirePlatformAdmin` plug** — checks `conn.assigns.current_user.email in UserAuth.admin_emails()`, else halts 403 JSON `{detail: "Forbidden"}`.
- [ ] **Step 2: Failing controller tests** — org-admin can `GET contract`/`GET invoices`; org-admin gets **403** on `PUT contract`/`POST activate`/`POST mark-paid` (not platform admin); a platform-admin (email in `:admin_emails`) can create/activate/mark-paid; non-member → 403; unknown org → 404; amounts are server-computed (a client-supplied `amount_cents` is ignored). (Set `:admin_emails` via `Application.put_env` in the test, `on_exit` restore — mirror the SSO test idiom.)
- [ ] **Step 3: Routes** — in the `:api` scope: `get "/orgs/:org_id/billing/contract"`, `get "/orgs/:org_id/billing/invoices"` (org-admin in-controller via `Organizations.admin?`); a nested scope `pipe_through [:api, RequirePlatformAdmin]` for `put "/orgs/:org_id/billing/contract"`, `post "/orgs/:org_id/billing/contract/activate"`, `post "/orgs/:org_id/billing/invoices/:id/mark-paid"`, `post "/orgs/:org_id/billing/invoices/:id/void"`.
- [ ] **Step 4: Controller** — `action_fallback PerfectPaperWeb.Api.FallbackController`; `:show` (org-admin: contract + `seats_used = Organizations.active_member_count`, contracted, overage, pool), `:invoices` (org-admin), `:configure`/`:activate`/`:mark_paid`/`:void` (platform-admin via the piped plug). Add a FallbackController clause for `{:error, :active_contract_exists}` → 409. OpenApiSpex-annotate; extend the api_docs coverage test.
- [ ] **Step 5: `billing_json.ex`** — render contract (no internal-only fields beyond what an admin sees) + invoice (number, period, amount_cents, status, due/paid). Money rendered as cents (+ a formatted string).
- [ ] **Step 6: Run → PASS** (controller + api_docs). Commit:
```bash
git add lib/perfect_paper_web/plugs/require_platform_admin.ex lib/perfect_paper_web/controllers/api/billing_controller.ex lib/perfect_paper_web/controllers/api/billing_json.ex lib/perfect_paper_web/router.ex lib/perfect_paper_web/api/schemas.ex test/perfect_paper_web/controllers/api/billing_controller_test.exs
git commit -m "feat(web): billing REST — org-admin view + platform-admin manage (contract/activate/mark-paid/void), OpenAPI"
```

---

## Task 7: LiveView — org-admin dashboard + internal admin + transparency copy

**Files:** Create `lib/perfect_paper_web/live/org_billing_live.ex` (+ `.heex`), `lib/perfect_paper_web/live/admin_live/billing.ex` (+ `.heex`). Modify `lib/perfect_paper_web/router.ex`, and the user settings/account template for the transparency line. Test `test/perfect_paper_web/live/org_billing_live_test.exs`, `test/perfect_paper_web/live/admin_live/billing_test.exs`.

- [ ] **Step 1: Failing LiveView tests** — org-admin can mount `/orgs/:org_id/billing` and sees seats used/contracted/overage + pool + invoices; non-admin redirected (mirror `ScimLive` mount: `Organizations.get_organization` + `Organizations.admin?` else `push_navigate(~p"/new")`). Internal `/admin/billing` under `live_session :require_admin` (platform-admin); a platform-admin can create + activate a contract and mark an invoice paid; a non-platform-admin is redirected.
- [ ] **Step 2: `OrgBillingLive`** (read-only org dashboard) — `mount` org-admin gate; assigns contract, `seats_used`, overage, pool (incl. negative), invoices. Template: discrete test ids (`#billing-seats-used`, `#billing-overage`, `#billing-pool`, `#invoice-<id>-status`), paper theme, money from cents, no emoji.
- [ ] **Step 3: `AdminLive.Billing`** (internal) — under the existing `live_session :require_admin` (platform-admin). Forms to create/activate/swap a contract and issue/mark-paid/void an invoice; lists across orgs. Discrete test ids.
- [ ] **Step 4: Transparency copy** — on the user account/settings LiveView, add a line: if the user has an active personal subscription AND belongs to an org with an active contract, render "Org workspaces are covered by **[Org]**'s enterprise plan; personal workspaces remain on your individual tier." (read-only; `Billing.has_active_contract?` + the user's membership). Discrete test id `#billing-context-note`.
- [ ] **Step 5: Routes** — `live "/orgs/:org_id/billing", OrgBillingLive, :index` in the authenticated browser `live_session`; `live "/admin/billing", AdminLive.Billing, :index` in `live_session :require_admin`.
- [ ] **Step 6: Run → PASS.** Commit:
```bash
git add lib/perfect_paper_web/live/org_billing_live.ex lib/perfect_paper_web/live/org_billing_live.html.heex lib/perfect_paper_web/live/admin_live/billing.ex lib/perfect_paper_web/live/admin_live/billing.html.heex lib/perfect_paper_web/router.ex test/perfect_paper_web/live/org_billing_live_test.exs test/perfect_paper_web/live/admin_live/billing_test.exs
git commit -m "feat(web): org-admin billing dashboard + internal /admin/billing + settings transparency copy"
```

---

## Task 8: Event assertions + pre-merge verification + merge

**Files:** Modify `test/perfect_paper/billing/*` (event assertions); `docs/compliance/soc2/controls.md` (optional CC-note).

- [ ] **Step 1: Event-emission assertions** — add to the relevant tests (subscribe then act, mirroring the SCIM event test): `contract.created` on create, `contract.activated` on activate, `invoice.issued` on issue, `invoice.paid` on mark-paid. Run those files green.
- [ ] **Step 2: Forced compile** — `MIX_TEST_PARTITION=billing mix compile --force --warnings-as-errors` clean; `grep -rn "TODO(billing)" lib/` lists deferred items (annual per-month overage; contract-expiry Oban sweep).
- [ ] **Step 3: Full precommit** — `MIX_TEST_PARTITION=billing mix precommit` green; `mix format`. Commit any format normalization with explicit paths.
- [ ] **Step 4: Merge to main** — verify `git branch --show-current` is `feat/enterprise-billing`; ensure `main` is free (not checked out elsewhere — it may be in a transient worktree); from a checkout that holds `main`, `git merge --no-ff feat/enterprise-billing`. Resolve the **`events/event.ex` `@types`** conflict if a parallel session also added types (combine both lists — this is the known recurring conflict). `mix compile --force --warnings-as-errors` + `MIX_TEST_PARTITION=billing mix test` green on merged main. Report "committed and merged back to main with no issues."

---

## Self-review (authoring)
- **Spec coverage:** schemas + partial unique active index + funded_credits (T1) ✓; create/activate(single-active)/cancel/swap + date-aware has_active_contract? (T2) ✓; active_member_count + atomic fund_pool + single-SQL high-water peak via member.* subscriber (T3) ✓; issue_invoice(fund+reset)/mark-paid/void(clawback) + non-enumerable number + activate-issues-first-invoice (T4) ✓; contract-aware charge_pool (fast path + negative soft floor) + route review charge by session ownership (T5) ✓; REST org-admin-view + platform-admin-manage + OpenAPI (T6) ✓; org-admin dashboard + internal admin + transparency (T7) ✓; events + verify + merge (T8) ✓.
- **Review-hardening coverage:** single-SQL high-water (T3); atomic swap (T2); void clawback via funded_credits (T4); hot-path allocation (T5); date-aware expiry (T2); negative soft floor `−(seats×credits×2)` (T5); internal-only management (T6/T7); roll-over funding (T4 `inc`); peak-concurrent + annual-overage limitation (documented in spec; `TODO(billing)` for Option B).
- **Type consistency:** `has_active_contract?/1`, `active_contract/1`, `contract_floor/1`, `fund_pool/2`, `active_member_count/1`, `charge_pool/2`, `issue_invoice/2`, `bump_peak_seats_for_event/1` are used identically across tasks; `funded_credits` flows schema→issue→void; `peak_seats_used` bumped (T3) → consumed+reset (T4).
- **Grounded-but-verify notes for implementers:** confirm the exact `History` review function + Multi shape before changing `charge_for_level` (T5 — keep its `{:ok,_}/{:error,_}` contract); confirm `Events.subscribe/1` + the children list location in `application.ex` (T3); confirm `errors_on/1` is available in `DataCase` (T1 tests); confirm the `:api` pipeline assigns `current_user` for the platform-admin plug (T6).
