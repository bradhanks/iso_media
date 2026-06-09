defmodule PerfectPaper.Credits do
  @moduledoc """
  Usage ledger and plan limits for PerfectPaper users.

  Credits are tracked via an append-only `credit_events` table: positive entries
  are grants and negative entries are charges. The current balance is derived by
  summing all events for a user.

  This is the public API and the only `Repo` boundary for the Credits context.
  """
  import Ecto.Query

  require Logger

  alias PerfectPaper.Repo
  alias PerfectPaper.Credits.{Campaign, Campaigns, CreditEvent, Notifier, Tier}
  alias PerfectPaper.Events

  # 1 credit = 1 full review.
  @proofreading_cost 1

  # Default thresholds when the user has no explicit setting.
  @default_threshold_annual 5
  @default_threshold_monthly 1

  # An annual subscription grants 12 months of allowance up front as one lump sum.
  @annual_months 12

  # PubSub topic carrying both domain triggers (`{:signup, payload}`, …) and the
  # resulting `{:credit_granted, payload}` announcements. Subscribers (the grant
  # runner and the email notifier) react independently — loosely coupled, so a
  # subscriber can be added, changed, or reined in without touching granting.
  @topic "credits:events"

  @doc "The PubSub topic for credit domain + result events."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to the credit event topic."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(PerfectPaper.PubSub, @topic)

  @doc """
  Announces a domain event (e.g. `:signup`, `:referral_accepted`,
  `:referral_purchase`) so subscribers can react. Fire-and-forget; emitters need
  not know what credits result.
  """
  @spec dispatch(atom(), map()) :: :ok
  def dispatch(trigger, payload \\ %{}) do
    Phoenix.PubSub.broadcast(PerfectPaper.PubSub, @topic, {trigger, Map.new(payload)})
  end

  # ── Campaign-driven grants ───────────────────────────────────────────────────

  @doc """
  Runs every campaign whose trigger matches `trigger`, against the event payload.
  Synchronous and transactional per grant — the `GrantServer` wraps this for
  async delivery, but tests call it directly. Returns the per-campaign results.
  """
  @spec apply_event(atom(), map()) :: [term()]
  def apply_event(trigger, payload) do
    ctx = payload |> Map.new() |> Map.put(:trigger, trigger)
    Enum.map(Campaigns.for_trigger(trigger), &run_campaign(&1, ctx))
  end

  @doc "Evaluates one campaign against a context and performs its grant if it passes."
  @spec run_campaign(Campaign.t(), map()) ::
          {:ok, CreditEvent.t()} | {:skip, atom()} | {:error, term()}
  def run_campaign(%Campaign{} = campaign, ctx) do
    target_id = Map.get(ctx, campaign.target)

    cond do
      is_nil(target_id) ->
        {:skip, :no_target}

      not Enum.all?(campaign.guards, & &1.(ctx)) ->
        {:skip, :guard}

      true ->
        key = dedup_key(campaign, ctx, target_id)

        target_id
        |> locked_insert(
          fn -> granted_before?(target_id, key) end,
          fn -> perform_effect(campaign.effect, target_id, key) end
        )
        |> case do
          {:ok, :already_granted} -> {:skip, :already_granted}
          other -> other
        end
    end
  end

  @doc """
  Converts `amount` credits from one bucket to another for a user (e.g. a
  referral's earned preview credit upgrading to paid): a −`amount` debit in
  `from` and a +`amount` credit in `to`, atomically.
  """
  @spec convert(
          Ecto.UUID.t(),
          :paid | :preview,
          :paid | :preview,
          pos_integer(),
          String.t(),
          keyword()
        ) ::
          {:ok, CreditEvent.t()} | {:error, term()}
  def convert(user_id, from, to, amount, reason, opts \\ []) do
    meta = dedup_metadata(opts[:dedup])

    Ecto.Multi.new()
    |> Ecto.Multi.run(:lock, fn repo, _ -> lock_user(repo, user_id) end)
    |> Ecto.Multi.run(:balance_check, fn _repo, _ ->
      if balance(user_id, from) >= amount,
        do: {:ok, :sufficient},
        else: {:error, :insufficient_credits}
    end)
    |> Ecto.Multi.insert(
      :debit,
      CreditEvent.create_changeset(%CreditEvent{}, %{
        user_id: user_id,
        amount: -amount,
        reason: reason,
        kind: from,
        metadata: meta
      })
    )
    |> Ecto.Multi.insert(
      :credit,
      CreditEvent.create_changeset(%CreditEvent{}, %{
        user_id: user_id,
        amount: amount,
        reason: reason,
        kind: to,
        metadata: meta
      })
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{credit: event}} -> {:ok, event}
      {:error, :balance_check, :insufficient_credits, _} -> {:error, :insufficient_credits}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Emails a writer that they received a free credit. Driven by `:credit_granted`
  events (the `NotifierServer` subscribes), so notification is decoupled from
  granting. No-ops for non-grant (charge) events.
  """
  @spec notify_granted(map()) :: :ok
  def notify_granted(%{user_id: user_id, amount: amount}) when amount > 0 do
    user = PerfectPaper.Accounts.get_user!(user_id)

    notify(fn ->
      Notifier.deliver_free_credit_granted(user.email, amount, balance(user_id), home_url())
    end)
  end

  def notify_granted(_event), do: :ok

  # ── Balance ──────────────────────────────────────────────────────────────────

  @doc "Returns the user's total credit balance across both buckets (sum of all events)."
  @spec balance(Ecto.UUID.t()) :: integer()
  def balance(user_id) do
    from(e in CreditEvent,
      where: e.user_id == ^user_id,
      select: coalesce(sum(e.amount), 0)
    )
    |> Repo.one()
  end

  @doc """
  Returns the user's balance in a single bucket: `:paid` (full-review credits)
  or `:preview` (free-preview credits).
  """
  @spec balance(Ecto.UUID.t(), :paid | :preview) :: integer()
  def balance(user_id, kind) when kind in [:paid, :preview] do
    from(e in CreditEvent,
      where: e.user_id == ^user_id and e.kind == ^kind,
      select: coalesce(sum(e.amount), 0)
    )
    |> Repo.one()
  end

  # ── Granting credits ─────────────────────────────────────────────────────────

  @doc """
  Records a credit grant for the user into a bucket (`:paid` full-review credits
  by default, or `:preview` free-preview credits). `reason` is a free-form label
  (e.g. "signup_bonus").
  """
  @spec grant(Ecto.UUID.t(), pos_integer(), String.t(), :paid | :preview) ::
          {:ok, CreditEvent.t()} | {:error, Ecto.Changeset.t()}
  def grant(user_id, amount, reason, kind \\ :paid)
      when is_integer(amount) and amount > 0 and kind in [:paid, :preview] do
    %CreditEvent{}
    |> CreditEvent.create_changeset(%{
      user_id: user_id,
      amount: amount,
      reason: reason,
      kind: kind
    })
    |> Repo.insert()
  end

  @doc """
  Grants a subscription's monthly review allowance into the ledger
  (1 credit = 1 full review), idempotent per calendar month.

  Safe to call repeatedly — at most one allowance is granted per user per period,
  so it can be driven from a subscribe action and (later) a monthly job alike.
  Plans with no allowance (`:preview` / unknown) grant nothing.

  Returns `{:ok, %CreditEvent{}}` on a fresh grant, `{:ok, :already_granted}` if
  this period's allowance was already given, or `{:ok, :no_allowance}` for a
  plan that grants none.
  """
  @spec grant_monthly_allowance(Ecto.UUID.t(), atom(), keyword()) ::
          {:ok, CreditEvent.t() | :already_granted | :no_allowance}
          | {:error, Ecto.Changeset.t()}
  def grant_monthly_allowance(user_id, plan, opts \\ []) do
    amount = Tier.for_plan(plan).monthly_reviews
    period = Keyword.get(opts, :period, current_period())
    reason = "monthly_allowance:#{period}"

    cond do
      amount <= 0 ->
        {:ok, :no_allowance}

      true ->
        locked_insert(
          user_id,
          fn -> allowance_granted?(user_id, reason) end,
          fn ->
            %CreditEvent{}
            |> CreditEvent.create_changeset(%{
              user_id: user_id,
              amount: amount,
              reason: reason,
              kind: :paid,
              metadata: %{
                "kind" => "monthly_allowance",
                "plan" => to_string(plan),
                "period" => period
              }
            })
            |> Repo.insert()
          end
        )
    end
  end

  @doc """
  Grants an annual subscription's review allowance up front as a single lump sum
  (12 × the plan's monthly allowance), idempotent **per subscription term**.

  Keyed on the term (`annual_allowance:{subscription_id}:{term_start}`), not the
  calendar month — so re-triggering within a term never double-grants, while a
  genuine renewal (a new `term_start`) grants afresh. Plans with no allowance
  grant nothing.

  Required `opts`: `:subscription_id`. Optional `:term_start` (defaults to the
  current `YYYY-MM` period). Returns `{:ok, %CreditEvent{}}` on a fresh grant,
  `{:ok, :already_granted}` if this term's allowance was already given, or
  `{:ok, :no_allowance}` for a plan that grants none.
  """
  @spec grant_annual_allowance(Ecto.UUID.t(), atom(), keyword()) ::
          {:ok, CreditEvent.t() | :already_granted | :no_allowance}
          | {:error, Ecto.Changeset.t()}
  def grant_annual_allowance(user_id, plan, opts \\ []) do
    subscription_id = Keyword.fetch!(opts, :subscription_id)
    term_start = Keyword.get(opts, :term_start, current_period())
    amount = Tier.for_plan(plan).monthly_reviews * @annual_months
    reason = "annual_allowance:#{subscription_id}:#{term_start}"

    if amount <= 0 do
      {:ok, :no_allowance}
    else
      locked_insert(
        user_id,
        fn -> allowance_granted?(user_id, reason) end,
        fn ->
          %CreditEvent{}
          |> CreditEvent.create_changeset(%{
            user_id: user_id,
            amount: amount,
            reason: reason,
            kind: :paid,
            metadata: %{
              "kind" => "annual_allowance",
              "plan" => to_string(plan),
              "subscription_id" => to_string(subscription_id),
              "term_start" => to_string(term_start)
            }
          })
          |> Repo.insert()
        end
      )
    end
  end

  @doc """
  Grants a subscription's monthly allowance in reaction to a `subscription.updated`
  domain event (emitted by `Billing` after the plan change commits). This is the
  synchronous core the `AllowanceServer` invokes when the event arrives, so the
  grant stays decoupled from Billing — Billing announces, Credits reacts.

  **Annual subscriptions are suppressed here:** they receive their full year as an
  up-front lump sum (`grant_annual_allowance/3`, via the purchase path), so the
  monthly drip must not also fire — otherwise an annual sub would get 12 lump + 12
  drip. The event payload carries `:billing_period`; when it is `:annual` this
  returns `{:ok, :annual_suppressed}` and grants nothing.

  Idempotent per month via `grant_monthly_allowance/3`. Returns `:ignore` for an
  event without a usable actor or plan.
  """
  @spec grant_monthly_allowance_for_event(Events.Event.t()) ::
          {:ok, CreditEvent.t() | :already_granted | :no_allowance | :annual_suppressed}
          | {:error, Ecto.Changeset.t()}
          | :ignore
  def grant_monthly_allowance_for_event(%Events.Event{actor_id: user_id, data: data})
      when is_binary(user_id) do
    cond do
      billing_period_from(data) == :annual ->
        {:ok, :annual_suppressed}

      true ->
        case plan_from(data) do
          nil -> :ignore
          plan -> grant_monthly_allowance(user_id, plan)
        end
    end
  end

  def grant_monthly_allowance_for_event(_event), do: :ignore

  defp plan_from(data) when is_map(data), do: Map.get(data, :plan) || Map.get(data, "plan")
  defp plan_from(_), do: nil

  # Only `:annual` matters (suppress the drip); any other / missing value is
  # treated as monthly so existing events (which carry no billing_period) keep
  # dripping. Matches the known atom/string forms only — no dynamic atom creation.
  defp billing_period_from(data) when is_map(data) do
    case Map.get(data, :billing_period) || Map.get(data, "billing_period") do
      :annual -> :annual
      "annual" -> :annual
      _ -> :monthly
    end
  end

  defp billing_period_from(_), do: :monthly

  @doc """
  Grants goodwill ("comp") credits to a user and records who issued the grant.

  Records a positive ledger entry whose `reason` is the operator's note and whose
  `metadata` captures attribution: `%{"kind" => "comp", "granted_by" => granted_by_id}`.
  """
  @spec comp_account(Ecto.UUID.t(), pos_integer(), String.t(), Ecto.UUID.t()) ::
          {:ok, CreditEvent.t()} | {:error, Ecto.Changeset.t()}
  def comp_account(user_id, amount, reason, granted_by_id)
      when is_integer(amount) and amount > 0 do
    %CreditEvent{}
    |> CreditEvent.create_changeset(%{
      user_id: user_id,
      amount: amount,
      reason: reason,
      metadata: %{"kind" => "comp", "granted_by" => granted_by_id}
    })
    |> Repo.insert()
  end

  @doc """
  Grants a free/bonus credit to a user and sends the celebratory activation
  email. Use this for signup bonuses and weekly free-credit drips — the kind of
  grant we want the user to notice and act on.

  Records the grant via `grant/3`, then emails the user their new balance. A
  failed email is logged and never rolls back the grant.
  """
  @spec grant_free_credit(struct(), pos_integer(), String.t()) ::
          {:ok, CreditEvent.t()} | {:error, Ecto.Changeset.t()}
  def grant_free_credit(%{id: user_id, email: email}, amount \\ 1, reason \\ "signup_bonus") do
    with {:ok, event} <- grant(user_id, amount, reason) do
      notify(fn ->
        Notifier.deliver_free_credit_granted(email, amount, balance(user_id), home_url())
      end)

      {:ok, event}
    end
  end

  @doc """
  Returns the effective credit alert threshold for a user (loads the user + their
  personal subscription, then delegates to `effective_low_credit_threshold/2`).

  Checks the user's explicit setting first. If unset, returns 5 for annual
  subscribers and 1 for monthly subscribers or those without a subscription.
  """
  @spec effective_alert_threshold(Ecto.UUID.t()) :: non_neg_integer()
  def effective_alert_threshold(user_id) do
    user = PerfectPaper.Accounts.get_user!(user_id)
    sub = PerfectPaper.Billing.get_subscription_for_user(user_id)
    effective_low_credit_threshold(user, sub)
  end

  @doc "Sends the low-balance nudge to a user based on their current balance."
  @spec notify_low_balance(struct()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def notify_low_balance(%{id: user_id, email: email}) do
    sub = PerfectPaper.Billing.get_subscription_for_user(user_id)
    billing_period = (sub && sub.billing_period) || :monthly
    Notifier.deliver_low_balance(email, balance(user_id), home_url(), billing_period)
  end

  @doc """
  Delivers the localized low-credit upsell email: the recipient's remaining
  `balance`, their `threshold`, the 12-pack price, and a copy variant for annual
  subscribers. Localized to `user.locale`. Email geo-pricing (per recipient
  country) is a Phase 2 enhancement — Phase 1 prices the pack at Band A.
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
      pack_reviews: 12,
      pack_price_cents: priced.price,
      cta_url: billing_url()
    })
  end

  def deliver_low_balance_upsell(_user, _balance, _threshold), do: {:error, :no_email}

  defp billing_url, do: PerfectPaperWeb.Endpoint.url() <> "/billing"

  # ── Charging credits ─────────────────────────────────────────────────────────

  @doc """
  Charges the proofreading cost (#{@proofreading_cost} credits) against the user's balance.

  Wraps the balance check and insert in a transaction so the check-then-insert
  is atomic. The third element of the success tuple, `crossed_low?`, reports
  whether THIS charge moved the balance from above the effective low-credit
  threshold to at/below it — the transaction owner emits `:"credits.low"`
  post-commit from it (this runs as a savepoint, so it can't emit itself).
  Returns `{:error, :insufficient_credits}` when the balance is too low.
  """
  @spec charge_for_proofreading(Ecto.UUID.t()) ::
          {:ok, CreditEvent.t(), boolean()} | {:error, :insufficient_credits}
  def charge_for_proofreading(user_id) when is_binary(user_id),
    do: charge(user_id, :paid, "proofreading")

  @doc """
  Charges one preview credit against the user's `:preview` bucket — used when a
  free-preview run should consume a granted preview credit. Returns
  `{:ok, event, crossed_low?}`, or `{:error, :insufficient_credits}` when no
  preview credits remain.
  """
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
  # subscription, then delegates to the pure `effective_low_credit_threshold/2`).
  defp effective_low_credit_threshold_for(user_id) do
    user = PerfectPaper.Accounts.get_user!(user_id)
    sub = PerfectPaper.Billing.get_subscription_for_user(user_id)
    effective_low_credit_threshold(user, sub)
  end

  @doc """
  The effective low-credit alert threshold for a user: their explicit
  `credit_alert_threshold` when set (including `0`, which the trigger treats as
  "disabled"), else the plan default — #{@default_threshold_annual} for a
  personal annual subscription, #{@default_threshold_monthly} otherwise.
  Pure; reads no IO. `subscription` is the user's personal
  `Billing.Subscription` or `nil`.
  """
  @spec effective_low_credit_threshold(
          %{credit_alert_threshold: integer() | nil},
          %{billing_period: atom()} | nil
        ) :: non_neg_integer()
  def effective_low_credit_threshold(%{credit_alert_threshold: t}, _sub) when is_integer(t), do: t

  def effective_low_credit_threshold(_user, %{billing_period: :annual}),
    do: @default_threshold_annual

  def effective_low_credit_threshold(_user, _sub), do: @default_threshold_monthly

  # ── Plan limits ──────────────────────────────────────────────────────────────

  @doc "Returns the word-count and monthly-credit limits for the given subscription plan."
  @spec limits_for(atom()) :: map()
  def limits_for(plan), do: Tier.for_plan(plan)

  # ── Email helpers ─────────────────────────────────────────────────────────────

  # Fire a notification email, logging (never raising) on failure so a mail
  # problem can't break a ledger write.
  defp notify(fun) do
    case fun.() do
      {:ok, _email} -> :ok
      {:error, reason} -> Logger.warning("Credits email failed: #{inspect(reason)}")
    end
  end

  defp home_url, do: PerfectPaperWeb.Endpoint.url()

  defp allowance_granted?(user_id, reason) do
    Repo.exists?(from(e in CreditEvent, where: e.user_id == ^user_id and e.reason == ^reason))
  end

  defp current_period do
    today = Date.utc_today()
    "#{today.year}-#{String.pad_leading(Integer.to_string(today.month), 2, "0")}"
  end

  # ── Concurrency control ──────────────────────────────────────────────────────

  # Serialize all ledger writes for one user inside the current transaction, so
  # a check-then-insert (balance or dedup) is atomic even under READ COMMITTED.
  # `pg_advisory_xact_lock` auto-releases at transaction end and is re-entrant,
  # so nesting (e.g. a campaign grant whose effect calls `convert/6`) is fine.
  defp lock_user(repo, user_id) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [user_id])
    {:ok, :locked}
  end

  # Run a guarded, per-user-serialized ledger write: take the lock, and if
  # `already?` reports the write was already made return `{:ok, :already_granted}`;
  # otherwise run `insert_fun` (which returns `{:ok, event} | {:error, reason}`).
  # A failed insert rolls the whole thing back, so no dedup marker is left behind.
  defp locked_insert(user_id, already?, insert_fun) do
    Repo.transaction(fn ->
      lock_user(Repo, user_id)

      if already?.() do
        :already_granted
      else
        case insert_fun.() do
          {:ok, event} -> event
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
    |> case do
      {:ok, :already_granted} -> {:ok, :already_granted}
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Campaign runner internals ────────────────────────────────────────────────

  defp perform_effect({:grant, kind, amount, reason}, user_id, dedup) do
    result =
      %CreditEvent{}
      |> CreditEvent.create_changeset(%{
        user_id: user_id,
        amount: amount,
        reason: reason,
        kind: kind,
        metadata: dedup_metadata(dedup)
      })
      |> Repo.insert()

    with {:ok, event} <- result do
      broadcast_granted(event)
      {:ok, event}
    end
  end

  defp perform_effect({:convert, from, to, amount, reason}, user_id, dedup) do
    with {:ok, event} <- convert(user_id, from, to, amount, reason, dedup: dedup) do
      broadcast_granted(event)
      {:ok, event}
    end
  end

  # Announce a grant so the notifier (and any future subscriber) can react.
  defp broadcast_granted(%CreditEvent{} = event) do
    Phoenix.PubSub.broadcast(
      PerfectPaper.PubSub,
      @topic,
      {:credit_granted,
       %{user_id: event.user_id, amount: event.amount, kind: event.kind, reason: event.reason}}
    )
  end

  defp dedup_key(%Campaign{filters: filters, effect: effect}, ctx, target_id) do
    case Enum.find(filters, fn {policy, _} -> policy == :once_per end) do
      {:once_per, opts} -> opts |> Keyword.fetch!(:key) |> apply([ctx])
      nil -> "#{effect_reason(effect)}:#{target_id}"
    end
  end

  defp effect_reason({:grant, _kind, _amount, reason}), do: reason
  defp effect_reason({:convert, _from, _to, _amount, reason}), do: reason

  defp granted_before?(user_id, key) do
    Repo.exists?(
      from(e in CreditEvent,
        where: e.user_id == ^user_id and fragment("?->>'dedup'", e.metadata) == ^key
      )
    )
  end

  defp dedup_metadata(nil), do: %{}
  defp dedup_metadata(key), do: %{"dedup" => key}
end
