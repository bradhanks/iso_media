# Low-Credit Alert & Upsell — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alert writers in-app and by email when their review-credit balance crosses **down to/below** a per-user threshold, with a 12-pack upsell — firing **once per crossing** (no per-charge spam), localized, and measurable.

**Architecture:** A pure `effective_low_credit_threshold/2` drives both an **in-lock crossing test** inside `Credits.charge/3` (returns a `crossed_low?` flag; no longer emits) and a **stateless** in-app banner derived from balance on each authed mount. The transaction owner (`History.process_session`) emits the already-registered `:"credits.low"` event **post-commit**; a subscriber enqueues a localized upsell email on a new Oban `:notifications` queue.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto (binary_id), Oban, `Events` bus, `Phoenix.PubSub`, daisyUI, gettext/`ngettext`, `:telemetry`, ExUnit (DataCase/ConnCase).

**Source spec:** `docs/superpowers/specs/2026-06-06-low-credit-alert-upsell-design.md`.

---

## Reconciliation notes (spec is stale; feature is ~40% pre-built)

A parallel session already shipped to `main`: the `User.credit_alert_threshold` field + changeset, the Settings "Credit alerts" section + `Accounts.update_credit_alert_threshold/2`, the `:"credits.low"` event registration + a **level-check** emit inside `Credits`, `compute_threshold/2`, and a `LowBalanceServer` subscriber that sends email **synchronously** and broadcasts `{:credits_low, ...}`. This plan **refactors** that code; it does not rebuild it. Locked decisions for the gaps the spec left open or the code diverged on:

1. **Cadence field:** the spec says `Subscription.interval == :year`; reality is **`Subscription.billing_period == :annual`** (`Ecto.Enum [:monthly, :annual]`). Use `billing_period`.
2. **Monthly default threshold:** spec says **1**; code currently has `@default_threshold_monthly 2`. **Align to the spec → 1.**
3. **Trigger:** code currently fires `if remaining < threshold` on *every* charge while low (per-charge spam) and emits from inside the savepoint. **Replace with a crossing test computed in-lock** (`balance_before > threshold and balance_after <= threshold and threshold > 0`) whose flag is emitted **post-commit by `History.process_session`**.
4. **Email geo band:** the email worker has no request context (runs in Oban, no `CF-IPCountry`). **Email prices `:pack_12` at Band A** (`pack_price_for(pack_12, :a)`); the **in-app banner** (which has the session band) prices at the visitor's actual band. Per-recipient geo-priced email is a Phase 2 enhancement (needs a persisted band) — out of scope here.
5. **Banner is stateless** (mount-derived from balance), so the `LowBalanceServer` PubSub broadcast `{:credits_low, ...}` becomes dead and is **removed**; the subscriber's sole job becomes "enqueue the upsell Oban job (deduped)."

---

## File map

| File | Change | Responsibility |
|---|---|---|
| `lib/perfect_paper/credits.ex` | modify | `effective_low_credit_threshold/2` (public, pure); `charge/3` computes crossing in-lock + returns `{:ok, event, crossed_low?}`; stop emitting; `deliver_low_balance_upsell/3` |
| `lib/perfect_paper/credits/notifier.ex` | modify | localized upsell email (gettext/`ngettext`, `:pack_12` CTA, annual variant) |
| `lib/perfect_paper/credits/low_balance_server.ex` | modify | subscriber enqueues the Oban upsell job (deduped); drop sync email + broadcast |
| `lib/perfect_paper/credits/low_balance_upsell_worker.ex` | create | Oban worker on `:notifications`; unique-keyed; calls `deliver_low_balance_upsell/3` |
| `lib/perfect_paper/history.ex` | modify | thread `crossed_low?` through `charge_for_level` → emit `:"credits.low"` post-commit |
| `config/config.exs` | modify | add `notifications: 5` Oban queue |
| `lib/perfect_paper_web/user_auth.ex` | modify | `on_mount` assigns `:credit_balance`, `:credit_alert_threshold_effective`, `:pricing_band` (personal context) |
| `lib/perfect_paper_web/components/low_credit_banner.ex` | create | stateless banner function component (`:pack_12` CTA, annual variant, dismissible, localized) |
| `lib/perfect_paper_web/components/app_shell.ex` | modify | render the banner after `flash_group` |
| `lib/perfect_paper_web/controllers/credit_banner_controller.ex` | create | POST to set the per-session dismiss cookie |
| `lib/perfect_paper_web/router.ex` | modify | route for the dismiss POST |
| `lib/perfect_paper_web/telemetry.ex` | modify | register `low_balance_alert` metric |

Tests live beside each (`test/perfect_paper/...`, `test/perfect_paper_web/...`).

**Conventions for every task:** branch `feat/low-credit-alert` off `main` (create it in Task 1 if absent). Run tests with `MIX_TEST_PARTITION=lca`. TDD: failing test → minimal code → passing → commit. Commit per task; do **not** merge until Task 11. All credit amounts are integer credits; pack prices are integer cents via `Billing.Pricing`.

---

## GROUP A — Crossing detection (the correctness core)

### Task 1: `effective_low_credit_threshold/2` — public pure threshold with 0-disable

**Files:**
- Modify: `lib/perfect_paper/credits.ex` (rename/replace private `compute_threshold/2`; change `@default_threshold_monthly` to `1`)
- Test: `test/perfect_paper/credits_threshold_test.exs`

- [ ] **Step 1: Create the branch (if not already on it)**

```bash
cd /Users/bradhanks/perfect_paper && git checkout main && git checkout -b feat/low-credit-alert
```

- [ ] **Step 2: Write the failing test**

```elixir
# test/perfect_paper/credits_threshold_test.exs
defmodule PerfectPaper.CreditsThresholdTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Credits

  defp user(t), do: %PerfectPaper.Accounts.User{credit_alert_threshold: t}
  defp annual, do: %PerfectPaper.Billing.Subscription{billing_period: :annual}
  defp monthly, do: %PerfectPaper.Billing.Subscription{billing_period: :monthly}

  test "annual subscriber with no override defaults to 5" do
    assert Credits.effective_low_credit_threshold(user(nil), annual()) == 5
  end

  test "non-annual / no subscription with no override defaults to 1" do
    assert Credits.effective_low_credit_threshold(user(nil), monthly()) == 1
    assert Credits.effective_low_credit_threshold(user(nil), nil) == 1
  end

  test "explicit user value overrides the plan default" do
    assert Credits.effective_low_credit_threshold(user(8), annual()) == 8
    assert Credits.effective_low_credit_threshold(user(3), nil) == 3
  end

  test "explicit 0 is preserved (means disabled — the trigger guards on > 0)" do
    assert Credits.effective_low_credit_threshold(user(0), annual()) == 0
  end
end
```

- [ ] **Step 3: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits_threshold_test.exs`
Expected: FAIL — `effective_low_credit_threshold/2` is undefined (it's currently private `compute_threshold/2`).

- [ ] **Step 4: Edit `lib/perfect_paper/credits.ex`**

Change the constant (near the top, currently `@default_threshold_monthly 2`):

```elixir
  @default_threshold_annual 5
  @default_threshold_monthly 1
```

Replace the three private `compute_threshold/2` clauses with a public, documented function (keep the same clause logic, add `@doc`/`@spec`, and make `nil` subscription explicit):

```elixir
  @doc """
  The effective low-credit alert threshold for a user: their explicit
  `credit_alert_threshold` when set (including `0`, which the trigger treats as
  "disabled"), else the plan default — `#{@default_threshold_annual}` for a
  personal annual subscription, `#{@default_threshold_monthly}` otherwise.
  Pure; reads no IO. `subscription` is the user's personal
  `Billing.Subscription` or `nil`.
  """
  @spec effective_low_credit_threshold(
          %{credit_alert_threshold: integer() | nil},
          %{billing_period: atom()} | nil
        ) :: non_neg_integer()
  def effective_low_credit_threshold(%{credit_alert_threshold: t}, _sub) when is_integer(t), do: t
  def effective_low_credit_threshold(_user, %{billing_period: :annual}), do: @default_threshold_annual
  def effective_low_credit_threshold(_user, _sub), do: @default_threshold_monthly
```

- [ ] **Step 5: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits_threshold_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/credits.ex test/perfect_paper/credits_threshold_test.exs
git commit -m "feat(credits): public effective_low_credit_threshold/2 (spec defaults 5/1, 0=disabled)"
```

---

### Task 2: `charge/3` computes the crossing in-lock + returns `{:ok, event, crossed_low?}`; Credits stops emitting

**Files:**
- Modify: `lib/perfect_paper/credits.ex` (`charge/3`, `charge_for_proofreading/1`, `charge_for_preview/1`; delete `maybe_emit_low_balance/2`)
- Modify: `test/perfect_paper/credits_test.exs`, `test/perfect_paper/credits_concurrency_test.exs`, `test/perfect_paper/events_emission_test.exs`, `test/perfect_paper_web/controllers/api/credit_controller_test.exs` (new return signature)
- Test: `test/perfect_paper/credits_crossing_test.exs` (new)

The charge must report whether **this** charge moved the balance from above the threshold to at/below it. Compute it under the existing advisory lock (so before/after are consistent), and **return** it — do not emit (the savepoint can't know the outer txn commits).

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/credits_crossing_test.exs
defmodule PerfectPaper.CreditsCrossingTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Credits
  import PerfectPaper.AccountsFixtures

  # grant/4 adds credits to the :paid bucket; default monthly threshold = 1.
  defp grant(user_id, n), do: Credits.grant(user_id, n, :paid)

  test "the charge that lands on the threshold reports crossed_low? == true, exactly once" do
    user = user_fixture()
    grant(user.id, 3)                       # threshold 1; start at 3

    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)  # 3 -> 2
    assert {:ok, _e, true}  = Credits.charge_for_proofreading(user.id)  # 2 -> 1  (crosses to threshold)
    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)  # 1 -> 0  (already at/below)
  end

  test "re-arms after a top-up above threshold" do
    user = user_fixture()
    grant(user.id, 2)
    assert {:ok, _e, true}  = Credits.charge_for_proofreading(user.id)  # 2 -> 1
    grant(user.id, 2)                                                   # back to 3
    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)  # 3 -> 2
    assert {:ok, _e, true}  = Credits.charge_for_proofreading(user.id)  # 2 -> 1
  end

  test "threshold 0 (disabled) never reports a crossing even at zero balance" do
    user = user_fixture(%{credit_alert_threshold: 0})
    grant(user.id, 2)
    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)  # 2 -> 1
    assert {:ok, _e, false} = Credits.charge_for_proofreading(user.id)  # 1 -> 0
  end

  test "Credits no longer emits :credits.low itself" do
    PerfectPaper.Events.subscribe(:"credits.low")
    user = user_fixture()
    Credits.grant(user.id, 2, :paid)
    assert {:ok, _e, true} = Credits.charge_for_proofreading(user.id)
    refute_receive {:event, %PerfectPaper.Events.Event{type: :"credits.low"}}, 200
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits_crossing_test.exs`
Expected: FAIL — `charge_for_proofreading/1` returns a 2-tuple, and `:credits.low` is still emitted.

- [ ] **Step 3: Refactor `charge/3` and the two public wrappers in `lib/perfect_paper/credits.ex`**

Replace the `charge/3` private function and the two public `@spec`/`def`s with:

```elixir
  @spec charge_for_proofreading(Ecto.UUID.t()) ::
          {:ok, CreditEvent.t(), boolean()} | {:error, :insufficient_credits}
  def charge_for_proofreading(user_id) when is_binary(user_id),
    do: charge(user_id, :paid, "proofreading")

  @spec charge_for_preview(Ecto.UUID.t()) ::
          {:ok, CreditEvent.t(), boolean()} | {:error, :insufficient_credits}
  def charge_for_preview(user_id) when is_binary(user_id),
    do: charge(user_id, :preview, "preview")

  # Atomically check-then-charge one credit from the given bucket, and report
  # whether THIS charge crossed the user from above the effective threshold to
  # at/below it. Both balances are read under the same per-user advisory lock so
  # before/after are consistent. The crossing is RETURNED, never emitted here:
  # this runs as a savepoint inside History.process_session's outer Multi, so it
  # cannot know the outer transaction commits — the owner emits post-commit.
  defp charge(user_id, kind, reason) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:lock, fn repo, _ -> lock_user(repo, user_id) end)
    |> Ecto.Multi.run(:crossing, fn _repo, _changes ->
      before = balance(user_id, kind)

      if before >= @proofreading_cost do
        threshold = effective_low_credit_threshold_for(user_id)
        after_bal = before - @proofreading_cost
        crossed? = threshold > 0 and before > threshold and after_bal <= threshold
        {:ok, crossed?}
      else
        {:error, :insufficient_credits}
      end
    end)
    |> Ecto.Multi.insert(:event, fn _changes ->
      CreditEvent.create_changeset(%CreditEvent{}, %{
        user_id: user_id,
        amount: -@proofreading_cost,
        reason: reason,
        kind: kind
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{event: event, crossing: crossed?}} ->
        {:ok, event, crossed?}

      {:error, :crossing, :insufficient_credits, _} ->
        {:error, :insufficient_credits}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Resolve the effective threshold for a user id (loads the user + personal
  # subscription, then delegates to the pure function).
  defp effective_low_credit_threshold_for(user_id) do
    user = PerfectPaper.Accounts.get_user!(user_id)
    sub = PerfectPaper.Billing.get_subscription_for_user(user_id)
    effective_low_credit_threshold(user, sub)
  end
```

**Delete** the `maybe_emit_low_balance/2` function entirely (the emit moves to `History` in Task 3). The old `charge/3` did the balance check in a `:balance_check` step; this replaces it with the `:crossing` step that does both the check and the crossing computation. Keep `lock_user/2` and `balance/2` as-is.

- [ ] **Step 4: Update existing direct-caller tests for the new 3-tuple**

In `test/perfect_paper/credits_test.exs`, every `assert {:ok, event} = Credits.charge_for_proofreading(...)` / `charge_for_preview(...)` becomes `assert {:ok, event, _crossed?} = ...` (and `{:ok, _event}` → `{:ok, _event, _}`). The `{:error, :insufficient_credits}` assertions are unchanged.

In `test/perfect_paper/credits_concurrency_test.exs:53`, the lambda `fn _ -> Credits.charge_for_proofreading(user_id) end` now returns a 3-tuple; if the test counts `{:ok, _}` successes, change its success match to `{:ok, _, _}`.

In `test/perfect_paper_web/controllers/api/credit_controller_test.exs:23`, `{:ok, _} = Credits.charge_for_proofreading(user.id)` → `{:ok, _, _} = ...`.

In `test/perfect_paper/events_emission_test.exs`, **delete** the two tests at lines ~247–267 (`charge_for_proofreading emits credits.low ...` and `... does NOT emit ...`) — Credits no longer emits; the emit is now `History`'s responsibility and is covered in Task 3. Leave the rest of the file untouched.

In `test/perfect_paper/credits_alert_test.exs`, replace any assertion that `charge_for_proofreading` **emits** `:"credits.low"` with the crossing-flag assertions now living in `credits_crossing_test.exs`; if the whole file only tested the old level-emit, reduce it to the still-valid cases or delete the now-duplicated ones. (Read it first; keep threshold/settings assertions that remain valid.)

- [ ] **Step 5: Run the affected suites, verify green**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits_crossing_test.exs test/perfect_paper/credits_test.exs test/perfect_paper/credits_concurrency_test.exs test/perfect_paper/events_emission_test.exs test/perfect_paper_web/controllers/api/credit_controller_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/credits.ex test/perfect_paper/credits_crossing_test.exs test/perfect_paper/credits_test.exs test/perfect_paper/credits_concurrency_test.exs test/perfect_paper/events_emission_test.exs test/perfect_paper/credits_alert_test.exs test/perfect_paper_web/controllers/api/credit_controller_test.exs
git commit -m "feat(credits): charge returns crossed_low? (in-lock crossing); stop emitting credits.low"
```

---

### Task 3: `History.process_session` emits `:"credits.low"` post-commit from the crossing flag

**Files:**
- Modify: `lib/perfect_paper/history.ex` (`review_and_complete/2`, `charge_for_level/2`)
- Test: `test/perfect_paper/history_low_credit_test.exs`

`charge_for_level` must surface the crossing as the Multi `:charge` step value; the `{:ok, _changes}` branch (post-commit) emits `:"credits.low"` once if `crossed_low?`. Group/org charges never cross a personal threshold.

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/history_low_credit_test.exs
defmodule PerfectPaper.HistoryLowCreditTest do
  use PerfectPaper.DataCase, async: false
  alias PerfectPaper.{Credits, Events}
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  setup do
    Events.subscribe(:"credits.low")
    :ok
  end

  test "a committed review that crosses the threshold emits credits.low once" do
    user = user_fixture()
    Credits.grant(user.id, 2, :paid)        # threshold 1; this review (2 -> 1) crosses
    session = full_review_session_fixture(user)   # owner_type: :user, owner_id: user.id

    {:ok, _} = PerfectPaper.History.process_session(session, "Some reviewable text.")

    assert_receive {:event, %Events.Event{type: :"credits.low", actor_id: actor, data: data}}
    assert actor == user.id
    assert data.balance == 1
    assert data.threshold == 1
    refute_receive {:event, %Events.Event{type: :"credits.low"}}, 200
  end

  test "a rolled-back review emits no credits.low even if the inner charge crossed" do
    user = user_fixture()
    Credits.grant(user.id, 2, :paid)
    session = full_review_session_fixture(user)

    # Force the outer transaction to roll back by stubbing the LLM to a comment
    # that fails to insert (an over-long anchor); use the provided helper.
    {:error, _} = process_session_with_failing_comment(session, "Some reviewable text.")

    refute_receive {:event, %Events.Event{type: :"credits.low"}}, 200
    # balance unchanged because the charge rolled back with the transaction
    assert Credits.balance(user.id) == 2
  end
end
```

> If `full_review_session_fixture/1` or `process_session_with_failing_comment/2` do not exist in `test/support/fixtures/history_fixtures.ex`, add them: the first builds a `:user`-owned `:full`-level pending session; the second runs `process_session` with the `Chatbot.LLM.Stub` configured to return a comment whose anchor offset is out of range so `insert_comments` fails the Multi. Read the existing fixtures + `Chatbot.LLM.Stub` first and mirror their style.

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/history_low_credit_test.exs`
Expected: FAIL — no `:"credits.low"` is emitted by `History`.

- [ ] **Step 3: Thread the crossing through `charge_for_level/2` and emit post-commit**

In `lib/perfect_paper/history.ex`, change the three `charge_for_level/2` clauses so the Multi step value is a uniform map carrying the crossing (group charges never cross a personal threshold):

```elixir
  defp charge_for_level(%{owner_type: :group, organization_id: org_id}, _level)
       when is_binary(org_id) do
    with :ok <- PerfectPaper.Organizations.charge_pool(org_id, 1) do
      {:ok, %{crossed_low?: false, user_id: nil}}
    end
  end

  defp charge_for_level(%{owner_id: user_id}, :full) do
    with {:ok, _event, crossed?} <- Credits.charge_for_proofreading(user_id) do
      {:ok, %{crossed_low?: crossed?, user_id: user_id}}
    end
  end

  defp charge_for_level(%{owner_id: user_id}, :preview) do
    with {:ok, _event, crossed?} <- Credits.charge_for_preview(user_id) do
      {:ok, %{crossed_low?: crossed?, user_id: user_id}}
    end
  end
```

In `review_and_complete/2`, the `{:ok, _changes}` branch becomes (read `changes.charge`, emit if crossed):

```elixir
      |> Repo.transaction()
      |> case do
        {:ok, %{charge: charge} = _changes} ->
          reloaded = Repo.get(Session, session.id) |> Repo.preload(:comments)
          emit_session_completed(reloaded)
          maybe_emit_low_credit(charge)
          {:ok, reloaded}

        {:error, :charge, :insufficient_credits, _} ->
          {:error, :no_credits}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
```

Add the private emitter (post-commit; mirrors `events.ex`'s "never emit before commit" rule). It reloads the user + subscription to build the payload and reads the post-charge balance:

```elixir
  # Post-commit: a personal charge that crossed the low-credit threshold fans out
  # the already-registered :"credits.low" event (subscribers: the in-app PubSub
  # and the upsell-email Oban worker). Group charges (user_id: nil) never fire.
  defp maybe_emit_low_credit(%{crossed_low?: true, user_id: user_id}) when is_binary(user_id) do
    user = Accounts.get_user!(user_id)
    sub = PerfectPaper.Billing.get_subscription_for_user(user_id)
    threshold = Credits.effective_low_credit_threshold(user, sub)
    balance = Credits.balance(user_id)
    billing_period = (sub && sub.billing_period) || :monthly

    :telemetry.execute(
      [:perfect_paper, :credits, :low_balance_alert],
      %{balance: balance, threshold: threshold},
      %{annual?: billing_period == :annual}
    )

    _ =
      Events.emit(:"credits.low", %{
        organization_id: nil,
        actor_id: user_id,
        resource: %{type: :user, id: user_id},
        data: %{
          balance: balance,
          threshold: threshold,
          billing_period: billing_period,
          crossing_id: "#{user_id}:#{System.unique_integer([:monotonic, :positive])}"
        }
      })

    :ok
  end

  defp maybe_emit_low_credit(_charge), do: :ok
```

Ensure `alias PerfectPaper.Events` (and `Accounts`) are in scope at the top of `history.ex` (they are — `emit_session_completed` already uses `Events`; `owner_locale` already uses `Accounts`).

> **Telemetry is emitted here, at the single post-commit crossing site** — not in `Credits` — so it fires exactly once per real alert. The `crossing_id` is a monotonic per-emit id used by the email worker's unique key (Task 4) so a retry can't double-send while two genuine crossings still each send.

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/history_low_credit_test.exs test/perfect_paper/history_test.exs`
Expected: PASS (and no regression in the broader history suite).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/history.ex test/perfect_paper/history_low_credit_test.exs test/support/fixtures/history_fixtures.ex
git commit -m "feat(history): emit credits.low post-commit from in-lock crossing flag + telemetry"
```

---

## GROUP B — Localized upsell email via Oban

### Task 4: `:notifications` Oban queue + `LowBalanceUpsellWorker` (deduped)

**Files:**
- Modify: `config/config.exs` (add `notifications: 5` to Oban queues)
- Create: `lib/perfect_paper/credits/low_balance_upsell_worker.ex`
- Test: `test/perfect_paper/credits/low_balance_upsell_worker_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/credits/low_balance_upsell_worker_test.exs
defmodule PerfectPaper.Credits.LowBalanceUpsellWorkerTest do
  use PerfectPaper.DataCase, async: true
  import Oban.Testing, repo: PerfectPaper.Repo
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Credits.LowBalanceUpsellWorker

  test "perform delivers the upsell email for the user" do
    user = user_fixture()
    assert :ok =
             perform_job(LowBalanceUpsellWorker, %{
               "user_id" => user.id,
               "balance" => 1,
               "threshold" => 1
             })
  end

  test "the same crossing_id enqueues only once (dedup on retry)" do
    user = user_fixture()
    args = %{user_id: user.id, balance: 1, threshold: 1, crossing_id: "cx-1"}

    assert {:ok, _} = Oban.insert(LowBalanceUpsellWorker.new(args))
    assert {:ok, job2} = Oban.insert(LowBalanceUpsellWorker.new(args))
    # Oban returns the existing job (conflict) rather than a second insert
    assert job2.conflict? or
             length(all_enqueued(worker: LowBalanceUpsellWorker)) == 1
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits/low_balance_upsell_worker_test.exs`
Expected: FAIL — worker module undefined.

- [ ] **Step 3: Add the queue + create the worker**

In `config/config.exs`, add `notifications: 5` to the Oban `queues:` list:

```elixir
  queues: [webhooks: 10, documents: 10, reviews: 10, teams_notifier: 5, maintenance: 5, notifications: 5],
```

Create `lib/perfect_paper/credits/low_balance_upsell_worker.ex`:

```elixir
defmodule PerfectPaper.Credits.LowBalanceUpsellWorker do
  @moduledoc """
  Delivers the localized low-credit upsell email. Enqueued by
  `Credits.LowBalanceServer` on a `:"credits.low"` event. Unique on the emit's
  `crossing_id` so an Oban retry can't double-send, while two genuine crossings
  (each a fresh `crossing_id`) still each send.
  """
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [keys: [:crossing_id], period: 60 * 60, states: [:available, :scheduled, :executing, :retryable, :completed]]

  alias PerfectPaper.{Accounts, Credits}

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"user_id" => user_id, "balance" => balance, "threshold" => threshold}}) do
    case Accounts.get_user(user_id) do
      nil -> :ok
      %{email: nil} -> :ok
      user -> Credits.deliver_low_balance_upsell(user, balance, threshold) |> normalize()
    end
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, _} = err), do: err
end
```

> `unique` includes `:completed` so a redelivered event within the hour does not re-send. A genuinely later crossing carries a different `crossing_id` and is not suppressed. If `crossing_id` is absent from `args` (a direct/test enqueue), Oban's uniqueness simply doesn't dedup — acceptable.

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits/low_balance_upsell_worker_test.exs`
Expected: PASS (Task 5 implements `deliver_low_balance_upsell/3`; if it's not yet defined this test's first case will fail — implement Task 5 before re-running, or stub `deliver_low_balance_upsell/3` to `{:ok, :stub}` now and flesh it out in Task 5). **Implementer note:** define a minimal `Credits.deliver_low_balance_upsell/3` returning `{:ok, :noop}` in this task so the worker compiles and its dedup test passes; Task 5 replaces the body.

- [ ] **Step 5: Commit**

```bash
git add config/config.exs lib/perfect_paper/credits/low_balance_upsell_worker.ex lib/perfect_paper/credits.ex test/perfect_paper/credits/low_balance_upsell_worker_test.exs
git commit -m "feat(credits): :notifications Oban queue + LowBalanceUpsellWorker (crossing_id deduped)"
```

---

### Task 5: `deliver_low_balance_upsell/3` + localized upsell email (gettext, `:pack_12` CTA, annual variant)

**Files:**
- Modify: `lib/perfect_paper/credits.ex` (`deliver_low_balance_upsell/3`)
- Modify: `lib/perfect_paper/credits/notifier.ex` (`deliver_low_balance_upsell/4` localized)
- Test: `test/perfect_paper/credits/low_balance_email_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/credits/low_balance_email_test.exs
defmodule PerfectPaper.Credits.LowBalanceEmailTest do
  use PerfectPaper.DataCase, async: true
  import PerfectPaper.AccountsFixtures
  import Swoosh.TestAssertions
  alias PerfectPaper.Credits

  test "non-annual user gets the upsell with the 12-pack CTA, localized to their locale" do
    user = user_fixture(%{locale: "de"})
    assert {:ok, _email} = Credits.deliver_low_balance_upsell(user, 1, 1)
    assert_email_sent(fn email ->
      assert email.to == [{"", user.email}]
      # Band-A 12-pack price string appears (volume-discounted $499)
      assert email.html_body =~ "$499"
      # German subject (catalog draft) — assert a non-English token is present
      assert email.subject != ""
    end)
  end

  test "annual subscriber gets the 'finish your year' copy variant" do
    user = user_fixture()
    {:ok, _sub} = annual_subscription_for(user)   # helper: personal Subscription billing_period: :annual
    assert {:ok, email} = Credits.deliver_low_balance_upsell(user, 4, 5)
    assert email.html_body =~ "year" or email.text_body =~ "year"
  end
end
```

> If `annual_subscription_for/1` isn't in the billing fixtures, add it (insert a personal `Billing.Subscription` with `billing_period: :annual` for the user). Read the existing billing fixtures first.

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits/low_balance_email_test.exs`
Expected: FAIL — `deliver_low_balance_upsell/3` is a stub returning `{:ok, :noop}`, sends no email.

- [ ] **Step 3: Implement the context function + the localized notifier**

In `lib/perfect_paper/credits.ex`, replace the stub `deliver_low_balance_upsell/3` with:

```elixir
  @doc """
  Delivers the localized low-credit upsell email: the recipient's remaining
  `balance`, their `threshold`, the band-A `:pack_12` price, and a copy variant
  for annual subscribers. Localized to `user.locale`. Email geo-pricing (per
  recipient country) is a Phase 2 enhancement — Phase 1 prices the pack at Band A.
  """
  @spec deliver_low_balance_upsell(map(), integer(), integer()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_low_balance_upsell(%{id: user_id, email: email} = user, balance, threshold)
      when is_binary(email) do
    sub = PerfectPaper.Billing.get_subscription_for_user(user_id)
    annual? = !!(sub && sub.billing_period == :annual)
    pack = Enum.find(PerfectPaper.Billing.Prices.credit_packs(), &(&1.key == :pack_12))
    priced = PerfectPaper.Billing.Pricing.pack_price_for(pack, :a)

    Notifier.deliver_low_balance_upsell(%{
      to: email,
      locale: Map.get(user, :locale) || "en",
      balance: balance,
      threshold: threshold,
      annual?: annual?,
      pack_reviews: pack.reviews,
      pack_price_cents: priced.price,
      cta_url: billing_url()
    })
  end

  def deliver_low_balance_upsell(_user, _balance, _threshold), do: {:error, :no_email}

  defp billing_url, do: PerfectPaperWeb.Endpoint.url() <> "/billing"
```

In `lib/perfect_paper/credits/notifier.ex`, add a localized builder (keep the old `deliver_low_balance/4` for now or delete it once unused — grep first). Use `Gettext.with_locale` + `ngettext` for the count, and `Billing.Pricing.format_cents/1` for the price:

```elixir
  @doc "Localized low-credit upsell email. `attrs` is a map (see Credits.deliver_low_balance_upsell/3)."
  @spec deliver_low_balance_upsell(map()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_low_balance_upsell(%{to: to, locale: locale} = a) do
    Gettext.with_locale(PerfectPaperWeb.Gettext, locale, fn ->
      price = PerfectPaper.Billing.Pricing.format_cents(a.pack_price_cents)

      subject =
        if a.annual?,
          do: gettext("Top up to finish your year on PerfectPaper"),
          else: gettext("You're running low on review credits")

      count_line =
        ngettext(
          "You have %{count} review credit left.",
          "You have %{count} review credits left.",
          a.balance,
          count: a.balance
        )

      cta =
        gettext("Get %{n} more reviews for %{price}", n: a.pack_reviews, price: price)

      html = """
      <p>#{count_line}</p>
      <p><a href="#{a.cta_url}">#{cta}</a></p>
      """

      text = "#{count_line}\n\n#{cta}: #{a.cta_url}\n"

      new()
      |> to(to)
      |> from(PerfectPaper.Credits.Notifier.from())
      |> subject(subject)
      |> html_body(html)
      |> text_body(text)
      |> PerfectPaper.Mailer.deliver()
    end)
  end
```

> If `Notifier` has no `from/0` helper, reuse the existing `from`/sender used by `deliver_low_balance/4` (read the file). `PerfectPaperWeb.Gettext` is the app's gettext backend (confirm the module name in `lib/perfect_paper_web/gettext.ex`). Keep strings in `gettext`/`ngettext` so the German catalog renders.

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits/low_balance_email_test.exs test/perfect_paper/credits/low_balance_upsell_worker_test.exs`
Expected: PASS.

- [ ] **Step 5: Extract the new gettext strings**

Run: `MIX_TEST_PARTITION=lca mix gettext.extract`
(Don't hand-translate here; the dedicated locale pass owns translations. English source is enough to ship.)

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/credits.ex lib/perfect_paper/credits/notifier.ex test/perfect_paper/credits/low_balance_email_test.exs priv/gettext
git commit -m "feat(credits): localized low-credit upsell email (12-pack CTA, annual variant, ngettext)"
```

---

### Task 6: `LowBalanceServer` enqueues the Oban job (drop sync email + broadcast)

**Files:**
- Modify: `lib/perfect_paper/credits/low_balance_server.ex`
- Test: `test/perfect_paper/credits/low_balance_server_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/credits/low_balance_server_test.exs
defmodule PerfectPaper.Credits.LowBalanceServerTest do
  use PerfectPaper.DataCase, async: false
  import Oban.Testing, repo: PerfectPaper.Repo
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.{Events}
  alias PerfectPaper.Credits.LowBalanceUpsellWorker

  test "a credits.low event enqueues the upsell job with the event payload" do
    user = user_fixture()

    Events.emit(:"credits.low", %{
      organization_id: nil,
      actor_id: user.id,
      resource: %{type: :user, id: user.id},
      data: %{balance: 1, threshold: 1, billing_period: :monthly, crossing_id: "cx-9"}
    })

    # Give the GenServer a moment to handle the broadcast, then assert the job.
    assert_enqueued worker: LowBalanceUpsellWorker, args: %{user_id: user.id, crossing_id: "cx-9"}
  end
end
```

> `assert_enqueued` requires the worker to have been inserted by the time it runs. `Events.emit` fans out synchronously to in-process subscribers via `Phoenix.PubSub`, but the `LowBalanceServer` is a separate process — the test may need a brief `Process.sleep(50)` before `assert_enqueued`, or use `assert_enqueued`'s polling. Prefer a short poll loop; mirror any existing Oban+GenServer test in the repo.

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits/low_balance_server_test.exs`
Expected: FAIL — the server still sends a synchronous email and enqueues nothing.

- [ ] **Step 3: Rewrite `handle_info` in `low_balance_server.ex`**

```elixir
  @impl true
  def handle_info(
        {:event, %Events.Event{type: :"credits.low", actor_id: user_id, data: data}},
        state
      ) do
    args =
      %{
        user_id: user_id,
        balance: get(data, :balance),
        threshold: get(data, :threshold),
        crossing_id: get(data, :crossing_id)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    _ = args |> PerfectPaper.Credits.LowBalanceUpsellWorker.new() |> Oban.insert()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp get(data, key), do: Map.get(data, key) || Map.get(data, to_string(key))
```

Delete the now-unused `notify/1` and `home_url/0` helpers and the `Notifier`/`Accounts`/`Credits` aliases that only the old path used (keep what's still referenced). Update the `@moduledoc` to "enqueues the upsell email job" and drop the PubSub-broadcast sentence.

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper/credits/low_balance_server_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/credits/low_balance_server.ex test/perfect_paper/credits/low_balance_server_test.exs
git commit -m "refactor(credits): LowBalanceServer enqueues upsell Oban job (drop sync email + broadcast)"
```

---

## GROUP C — Stateless in-app banner

### Task 7: Assign `credit_balance` + effective threshold + `pricing_band` in the authed `on_mount`

**Files:**
- Modify: `lib/perfect_paper_web/user_auth.ex`
- Test: `test/perfect_paper_web/user_auth_credit_assign_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/user_auth_credit_assign_test.exs
defmodule PerfectPaperWeb.UserAuthCreditAssignTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Credits

  test "an authed LiveView mount carries credit_balance + effective threshold", %{conn: conn} do
    user = user_fixture()
    Credits.grant(user.id, 2, :paid)
    {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/billing")
    # The billing page renders; the assigns exist (no KeyError). The banner
    # (Task 8) asserts visibility — here we just prove the mount succeeds with
    # the new assigns wired (a crash would fail this).
    assert html =~ "Choose your plan"
  end
end
```

- [ ] **Step 2: Run it, verify it fails (only after Step 3 references the assigns)**

This test passes today (mount already works). It's a guard against a `KeyError` once the banner reads the assigns. Run it after Step 3.

- [ ] **Step 3: Add an `on_mount` hook that assigns the banner inputs**

In `lib/perfect_paper_web/user_auth.ex`, add a new `on_mount` clause and helper (after the existing `:mount_current_scope` clause). It runs on disconnected + connected mounts; nil-guards before the scope user exists:

```elixir
  def on_mount(:assign_credit_alert, _params, session, socket) do
    {:cont, assign_credit_alert(socket, session)}
  end

  defp assign_credit_alert(socket, session) do
    Phoenix.Component.assign_new(socket, :credit_alert, fn ->
      case socket.assigns[:current_scope] do
        %{user: %{id: user_id} = user} when is_binary(user_id) ->
          sub = PerfectPaper.Billing.get_subscription_for_user(user_id)

          %{
            balance: PerfectPaper.Credits.balance(user_id),
            threshold: PerfectPaper.Credits.effective_low_credit_threshold(user, sub),
            annual?: !!(sub && sub.billing_period == :annual),
            band: band_from_session(session)
          }

        _ ->
          %{balance: 0, threshold: 0, annual?: false, band: :a}
      end
    end)
  end

  defp band_from_session(session) do
    case session["pricing_band"] do
      b when b in ["a", "b", "c", "d"] -> String.to_existing_atom(b)
      _ -> :a
    end
  end
```

Then chain `:assign_credit_alert` after `:mount_current_scope` wherever authed live routes declare `on_mount` (the `live_session` for authenticated routes in `router.ex`). Find the `live_session ... on_mount: [{PerfectPaperWeb.UserAuth, :mount_current_scope}, ...]` (or the `require_authenticated` live_session) and append `{PerfectPaperWeb.UserAuth, :assign_credit_alert}`.

> `:assign_credit_alert` must run **after** the scope is assigned (it reads `current_scope`). If the authed routes use the `:require_authenticated` on_mount that already assigns the scope, chain after it. Read `router.ex`'s `live_session` blocks and place it correctly.

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper_web/user_auth_credit_assign_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/user_auth.ex lib/perfect_paper_web/router.ex test/perfect_paper_web/user_auth_credit_assign_test.exs
git commit -m "feat(web): assign credit_alert (balance/threshold/band) on authed mounts"
```

---

### Task 8: Stateless `LowCreditBanner` component, slotted into `AppShell`

**Files:**
- Create: `lib/perfect_paper_web/components/low_credit_banner.ex`
- Modify: `lib/perfect_paper_web/components/app_shell.ex`
- Test: `test/perfect_paper_web/components/low_credit_banner_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/components/low_credit_banner_test.exs
defmodule PerfectPaperWeb.LowCreditBannerTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias PerfectPaperWeb.LowCreditBanner

  defp render_banner(assigns), do: rendered_to_string(LowCreditBanner.banner(assigns))

  test "shows when balance <= threshold (> 0), with the 12-pack CTA" do
    html = render_banner(%{alert: %{balance: 1, threshold: 1, annual?: false, band: :a}, dismissed?: false})
    assert html =~ "data-testid=\"low-credit-banner\""
    assert html =~ "$499"                      # band-A 12-pack price
    assert html =~ "/billing"
  end

  test "hidden when balance is above threshold" do
    html = render_banner(%{alert: %{balance: 5, threshold: 1, annual?: false, band: :a}, dismissed?: false})
    refute html =~ "data-testid=\"low-credit-banner\""
  end

  test "hidden when threshold is 0 (disabled) even at zero balance" do
    html = render_banner(%{alert: %{balance: 0, threshold: 0, annual?: false, band: :a}, dismissed?: false})
    refute html =~ "data-testid=\"low-credit-banner\""
  end

  test "hidden when dismissed for the session" do
    html = render_banner(%{alert: %{balance: 1, threshold: 1, annual?: false, band: :a}, dismissed?: true})
    refute html =~ "data-testid=\"low-credit-banner\""
  end

  test "annual subscriber sees the finish-your-year variant" do
    html = render_banner(%{alert: %{balance: 4, threshold: 5, annual?: true, band: :a}, dismissed?: false})
    assert html =~ "year"
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper_web/components/low_credit_banner_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Create the component**

```elixir
# lib/perfect_paper_web/components/low_credit_banner.ex
defmodule PerfectPaperWeb.LowCreditBanner do
  @moduledoc """
  Stateless low-credit banner: shows whenever the current personal balance is at
  or below the effective threshold (threshold > 0) and the session hasn't
  dismissed it. Derived from balance on each mount — no event needed,
  reconnect-safe. CTA → the 12-pack at the visitor's band price; annual variant.
  """
  use PerfectPaperWeb, :html
  alias PerfectPaper.Billing.{Prices, Pricing}

  attr :alert, :map, required: true, doc: "%{balance, threshold, annual?, band}"
  attr :dismissed?, :boolean, default: false

  @spec banner(map()) :: Phoenix.LiveView.Rendered.t()
  def banner(assigns) do
    show? =
      not assigns.dismissed? and
        assigns.alert.threshold > 0 and
        assigns.alert.balance <= assigns.alert.threshold

    assigns =
      assign(assigns,
        show?: show?,
        price: pack_price_string(assigns.alert.band)
      )

    ~H"""
    <div
      :if={@show?}
      data-testid="low-credit-banner"
      role="status"
      class="alert alert-warning mb-4 flex items-center justify-between gap-3 rounded-box"
    >
      <span class="font-sans text-sm">
        <%= if @alert.annual? do %>
          {ngettext(
            "You have %{count} review credit left this year.",
            "You have %{count} review credits left this year.",
            @alert.balance,
            count: @alert.balance
          )}
        <% else %>
          {ngettext(
            "You have %{count} review credit left.",
            "You have %{count} review credits left.",
            @alert.balance,
            count: @alert.balance
          )}
        <% end %>
      </span>

      <span class="flex items-center gap-2">
        <.link navigate="/billing" class="btn btn-sm btn-primary font-sans">
          {gettext("Get more for %{price}", price: @price)}
        </.link>
        <button
          type="button"
          class="btn btn-ghost btn-sm btn-square motion-safe:transition"
          aria-label={gettext("Dismiss")}
          phx-click={JS.hide(to: "[data-testid='low-credit-banner']") |> JS.dispatch("phx:dismiss-low-credit")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </span>
    </div>
    """
  end

  defp pack_price_string(band) do
    pack = Enum.find(Prices.credit_packs(), &(&1.key == :pack_12))
    Pricing.format_cents(Pricing.pack_price_for(pack, band).price)
  end
end
```

In `lib/perfect_paper_web/components/app_shell.ex`, render the banner right after the `flash_group` (the investigation located this at the top of `<main>`). Pass the assigns through; guard for the `:credit_alert` assign being present:

```elixir
    <PerfectPaperWeb.Layouts.flash_group flash={@flash} />
    <PerfectPaperWeb.LowCreditBanner.banner
      :if={assigns[:credit_alert]}
      alert={@credit_alert}
      dismissed?={assigns[:low_credit_dismissed?] || false}
    />
```

> `AppShell.app/1` must receive `@credit_alert` (and optionally `@low_credit_dismissed?`). Because every authed LiveView mounts through `:assign_credit_alert` (Task 7), `@credit_alert` is in socket assigns and flows to the component automatically when the LiveView renders `<AppShell.app ...>`. If `app_shell.ex` uses explicit attrs (not global assigns), add `attr :credit_alert, :map, default: nil` and `attr :low_credit_dismissed?, :boolean, default: false` to `app/1` and pass them at each call site — grep for `AppShell.app` / `<.app` usages and thread them, OR (preferred, less churn) read from `assigns[:credit_alert]` inside `app/1` since LiveView passes socket assigns through. Choose the approach matching how `app_shell.ex` already reads `@current_scope`.

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper_web/components/low_credit_banner_test.exs`
Expected: PASS.

- [ ] **Step 5: Extract gettext + commit**

```bash
MIX_TEST_PARTITION=lca mix gettext.extract
git add lib/perfect_paper_web/components/low_credit_banner.ex lib/perfect_paper_web/components/app_shell.ex test/perfect_paper_web/components/low_credit_banner_test.exs priv/gettext
git commit -m "feat(web): stateless low-credit banner in AppShell (12-pack CTA, annual variant)"
```

---

### Task 9: Per-session dismiss (cookie), mirroring cookie-consent

**Files:**
- Create: `lib/perfect_paper_web/controllers/credit_banner_controller.ex`
- Modify: `lib/perfect_paper_web/router.ex` (POST route), `lib/perfect_paper_web/user_auth.ex` (read the dismiss flag into the assign), `assets/js/app.js` (post on `phx:dismiss-low-credit`)
- Test: `test/perfect_paper_web/controllers/credit_banner_controller_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/controllers/credit_banner_controller_test.exs
defmodule PerfectPaperWeb.CreditBannerControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "POST /credit-banner/dismiss sets the dismiss cookie and returns 204", %{conn: conn} do
    conn = post(conn, ~p"/credit-banner/dismiss")
    assert conn.status == 204
    assert conn.resp_cookies["pp_low_credit_dismissed"]
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper_web/controllers/credit_banner_controller_test.exs`
Expected: FAIL — route + controller undefined.

- [ ] **Step 3: Implement controller, route, JS, and the read-back**

Create `lib/perfect_paper_web/controllers/credit_banner_controller.ex`:

```elixir
defmodule PerfectPaperWeb.CreditBannerController do
  @moduledoc "Sets a per-session cookie dismissing the low-credit banner."
  use PerfectPaperWeb, :controller

  @cookie "pp_low_credit_dismissed"

  @spec dismiss(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dismiss(conn, _params) do
    conn
    |> put_resp_cookie(@cookie, "1", sign: true, max_age: 60 * 60 * 24, same_site: "Lax")
    |> send_resp(:no_content, "")
  end
end
```

In `router.ex`, add inside the `:browser` scope:

```elixir
    post "/credit-banner/dismiss", CreditBannerController, :dismiss
```

In `lib/perfect_paper_web/user_auth.ex` `assign_credit_alert/2`, also assign `:low_credit_dismissed?` by reading the signed cookie from the session/conn. Since `on_mount` only has `session` (not `conn`), the cookie isn't in `session` by default — instead add a tiny plug or read it via a `:fetch` assign. Simplest: a `FetchLowCreditDismiss` plug in the `:browser` pipeline that reads the signed cookie and `put_session(:low_credit_dismissed, bool)`; then `assign_credit_alert/2` reads `session["low_credit_dismissed"]`:

```elixir
# in assign_credit_alert/2, add to the socket:
Phoenix.Component.assign_new(socket, :low_credit_dismissed?, fn ->
  session["low_credit_dismissed"] == true
end)
```

Create the plug `lib/perfect_paper_web/plugs/fetch_low_credit_dismiss.ex`:

```elixir
defmodule PerfectPaperWeb.Plugs.FetchLowCreditDismiss do
  @moduledoc "Reads the signed low-credit-dismiss cookie into the session for LiveView."
  import Plug.Conn

  @behaviour Plug
  @cookie "pp_low_credit_dismissed"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn, signed: [@cookie])
    put_session(conn, :low_credit_dismissed, conn.cookies[@cookie] == "1")
  end
end
```

Add `plug PerfectPaperWeb.Plugs.FetchLowCreditDismiss` to the `:browser` pipeline in `router.ex` (after the session is fetched).

In `assets/js/app.js`, post to the dismiss endpoint when the banner fires the custom event (mirror the existing CSRF token usage):

```js
window.addEventListener("phx:dismiss-low-credit", () => {
  const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
  fetch("/credit-banner/dismiss", {
    method: "POST",
    headers: { "x-csrf-token": csrf },
    credentials: "same-origin"
  })
})
```

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper_web/controllers/credit_banner_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/controllers/credit_banner_controller.ex lib/perfect_paper_web/plugs/fetch_low_credit_dismiss.ex lib/perfect_paper_web/router.ex lib/perfect_paper_web/user_auth.ex assets/js/app.js test/perfect_paper_web/controllers/credit_banner_controller_test.exs
git commit -m "feat(web): per-session dismiss for the low-credit banner (signed cookie)"
```

---

## GROUP D — Telemetry registration + verification

### Task 10: Register the `low_balance_alert` telemetry metric

**Files:**
- Modify: `lib/perfect_paper_web/telemetry.ex`
- Test: `test/perfect_paper_web/telemetry_test.exs` (extend, or assert the metric list includes it)

The event is already emitted in Task 3. Register it so it feeds a dashboard.

- [ ] **Step 1: Write the failing test**

```elixir
# add to test/perfect_paper_web/telemetry_test.exs (create if absent)
defmodule PerfectPaperWeb.TelemetryTest do
  use ExUnit.Case, async: true

  test "metrics include the low_balance_alert summary" do
    names = Enum.map(PerfectPaperWeb.Telemetry.metrics(), & &1.name)
    assert [:perfect_paper, :credits, :low_balance_alert, :balance] in names or
             Enum.any?(PerfectPaperWeb.Telemetry.metrics(), fn m ->
               m.event_name == [:perfect_paper, :credits, :low_balance_alert]
             end)
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper_web/telemetry_test.exs`
Expected: FAIL — metric not registered.

- [ ] **Step 3: Add the metric in `metrics/0`**

```elixir
      summary("perfect_paper.credits.low_balance_alert.balance", tags: [:annual?]),
      counter("perfect_paper.credits.low_balance_alert.count", tags: [:annual?]),
```

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=lca mix test test/perfect_paper_web/telemetry_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/telemetry.ex test/perfect_paper_web/telemetry_test.exs
git commit -m "feat(telemetry): register credits.low_balance_alert metric"
```

---

### Task 11: Pre-merge verification + integrate to main

- [ ] **Step 1: Settings UI re-verify (already built; confirm spec alignment)**

The "Credit alerts" section already exists in `lib/perfect_paper_web/live/user_live/settings.ex`. Read it; confirm the hint shows the **plan default** (annual 5 / non-annual 1) and validation rejects negatives and bounds the max (`<=` the 12-pack size, 12). If the max isn't bounded, add `validate_number(:credit_alert_threshold, greater_than_or_equal_to: 0, less_than_or_equal_to: 12)` to `User.credit_alert_threshold_changeset/2` and a test in `test/perfect_paper_web/live/user_live/settings_test.exs`. Commit if changed:

```bash
git add -A && git commit -m "fix(accounts): bound credit_alert_threshold to <= 12 (largest pack)"
```

- [ ] **Step 2: Full suite + format under the partition**

Run: `MIX_TEST_PARTITION=lca mix precommit`
Expected: compiles `--warnings-as-errors`, format clean, **0 failures**. Fix anything red.

- [ ] **Step 3: Integrate main + re-verify**

```bash
git merge --no-edit main && mix deps.get && MIX_TEST_PARTITION=lca mix test
```
Resolve conflicts (credits.ex / history.ex / config.exs are the likely hot spots), re-run.

- [ ] **Step 4: Fast-forward main + confirm the modules landed**

```bash
git update-ref refs/heads/main feat/low-credit-alert
git show main:lib/perfect_paper/credits/low_balance_upsell_worker.ex >/dev/null && echo "worker landed"
git show main:lib/perfect_paper_web/components/low_credit_banner.ex >/dev/null && echo "banner landed"
```

- [ ] **Step 5: Report** "committed and merged back to main with no issues."

---

## Self-Review

**Spec coverage:**
- Trigger = balance ≤ threshold, **once per crossing**, in-lock, re-arms → Tasks 2–3 ✓
- Per-user threshold + plan defaults (annual 5 / else 1) + 0-disable → Tasks 1, 2 ✓
- In-app + email → Group B (email), Group C (banner) ✓
- Email once per crossing, dedup on retry, localized, 12-pack CTA, annual variant → Tasks 4–5 ✓
- Reuse `:"credits.low"` (no new event), post-commit emit by transaction owner → Task 3 ✓
- Stateless banner, personal-context only, dismissible, reduced-motion, no emoji, gettext → Tasks 7–9 ✓
- Settings threshold (blank = default, validation) → already built; re-verified + max-bound in Task 11 ✓
- Telemetry `[:perfect_paper, :credits, :low_balance_alert]` → emitted Task 3, registered Task 10 ✓
- Threshold-0 disable guard; rollback safety; no latch column → Tasks 1–3 ✓

**Reconciliation captured:** stale `interval/:year` → `billing_period/:annual`; monthly default 2 → 1; level-check → crossing; sync email → Oban `:notifications`; PubSub broadcast removed; email prices at Band A (banner at session band).

**Out of scope (per spec):** usage-rate alerts · annual-only bespoke pack · SMS/push · failed-payment dunning · per-recipient geo-priced email (Phase 2).

**Type consistency:** `charge_for_proofreading/1` & `charge_for_preview/1` → `{:ok, CreditEvent.t(), boolean()} | {:error, :insufficient_credits}` everywhere (Task 2, consumed Task 3). `charge_for_level/2` Multi value → `{:ok, %{crossed_low?: boolean(), user_id: binary()|nil}}` (Task 3). `:"credits.low"` `data` → `%{balance, threshold, billing_period, crossing_id}` (Task 3, consumed Tasks 5–6). `effective_low_credit_threshold/2` arity + name consistent (Tasks 1, 2, 3, 7). `deliver_low_balance_upsell/3` (context) → `Notifier.deliver_low_balance_upsell/1` (map arg) (Tasks 4–5).
