defmodule PerfectPaper.Billing do
  @moduledoc """
  Subscription and billing management — the sole public API and the only
  `Repo`/IO boundary for the Billing context.

  Payments are handled through a configurable adapter selected at runtime:

      config :perfect_paper, :billing_provider, PerfectPaper.Billing.StubAdapter

  The adapter is the only module that references vendor-specific details. It
  returns atom-keyed maps matching `Subscription` schema fields so results can
  be passed directly into changesets.
  """

  import Ecto.Query

  alias PerfectPaper.{Repo, Credits, Events, Organizations}

  alias PerfectPaper.Billing.{
    Contract,
    Invoice,
    Subscription,
    Prices,
    Notifier,
    Pricing,
    PricingAudit,
    RiskSignals,
    WebhookEvent
  }

  alias PerfectPaper.Accounts.User

  # ── Reading ────────────────────────────────────────────────────────────────

  @doc "Returns a user's subscription, or nil if they have none."
  @spec get_subscription_for_user(Ecto.UUID.t()) :: Subscription.t() | nil
  def get_subscription_for_user(user_id) do
    Repo.get_by(Subscription, user_id: user_id)
  end

  # ── Upgrading / changing plan ──────────────────────────────────────────────

  @doc """
  Creates or upgrades a subscription to the given plan for a user.

  Calls the payments provider to create a customer and subscription, then
  upserts the `Subscription` record. If the user already has a subscription,
  their existing record is updated; otherwise a new one is inserted.
  """
  @spec upgrade_plan(struct(), atom()) :: {:ok, Subscription.t()} | {:error, term()}
  def upgrade_plan(user, plan) do
    with {:ok, customer_attrs} <- provider().create_customer(%{email: user.email}),
         {:ok, sub_attrs} <-
           provider().create_subscription(Map.merge(customer_attrs, %{plan: plan})) do
      attrs =
        customer_attrs
        |> Map.merge(sub_attrs)
        |> Map.merge(%{user_id: user.id, plan: plan})

      result =
        case get_subscription_for_user(user.id) do
          nil ->
            %Subscription{}
            |> Subscription.create_changeset(attrs)
            |> Repo.insert()

          existing ->
            existing
            |> Subscription.change_plan_changeset(attrs)
            |> Repo.update()
        end

      with {:ok, subscription} <- result do
        # A referred buyer "converts" their referrer's earned preview credit to
        # paid — announce it; the Credits campaign does the upgrade.
        if referrer_id = PerfectPaper.Referrals.referrer_id_for(user.id) do
          Credits.dispatch(:referral_purchase, %{referrer_id: referrer_id, referee_id: user.id})
        end

        # Announce the plan change after commit. Credits reacts to this to drop
        # this month's review allowance into the ledger (idempotent per month) —
        # see Credits.grant_monthly_allowance_for_event/1 — so Billing no longer
        # reaches into Credits to grant directly.
        _ = emit_subscription_updated(user.id, subscription)

        {:ok, subscription}
      end
    end
  end

  @doc """
  Purchases (or changes) a personal subscription at a cadence — the Phase-2 atomic
  path. Resolves the regional price, persists the subscription with its cadence +
  applied pricing, grants the entitlement, and records the pricing-decision audit,
  so a partial purchase is impossible. **Personal-path only** (an org/group
  context → `{:error, :org_purchase_unsupported}`).

  For an **annual** cadence the full year's allowance is granted up front as a lump
  (`Credits.grant_annual_allowance/3`) **inside** the purchase transaction; for
  **monthly** the allowance is dripped by the post-commit `subscription.updated`
  event (which the annual path suppresses). On the stub `payment_country` is `nil`
  → Band A for the binding price; Phase-2-real supplies the payment country.
  """
  @spec subscribe(
          User.t(),
          atom(),
          :monthly | :annual,
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: {:ok, Subscription.t()} | {:error, term()}
  def subscribe(user, plan, cadence, ip_country, payment_country, opts \\ [])

  def subscribe(%User{} = user, plan, cadence, ip_country, payment_country, opts) do
    band = Pricing.resolve_band(ip_country, payment_country)
    billing_period = if cadence == :annual, do: :annual, else: :monthly

    case Enum.find(Prices.subscriptions(), &(&1.key == plan)) do
      nil ->
        {:error, :unknown_plan}

      plan_map ->
        price = Pricing.price_for(plan_map, band)
        applied = if cadence == :annual, do: price.annual_price, else: price.monthly_price

        with {:ok, customer_attrs} <- provider().create_customer(%{email: user.email}),
             {:ok, sub_attrs} <-
               provider().create_subscription(Map.merge(customer_attrs, %{plan: plan})) do
          attrs =
            customer_attrs
            |> Map.merge(sub_attrs)
            |> Map.merge(%{
              user_id: user.id,
              plan: plan,
              billing_period: billing_period,
              applied_band: to_string(band),
              applied_cents: applied
            })

          multi =
            Ecto.Multi.new()
            |> Ecto.Multi.run(:subscription, fn _repo, _ ->
              upsert_subscription(user.id, attrs)
            end)
            |> Ecto.Multi.run(:grant, fn _repo, %{subscription: sub} ->
              # Annual = lump up front, in-transaction; monthly drips via the event.
              if billing_period == :annual do
                Credits.grant_annual_allowance(user.id, plan, subscription_id: sub.id)
              else
                {:ok, :monthly_via_event}
              end
            end)

          case Repo.transaction(multi) do
            {:ok, %{subscription: subscription}} ->
              after_subscribe(
                user,
                subscription,
                plan,
                cadence,
                ip_country,
                payment_country,
                opts
              )

              {:ok, subscription}

            {:error, _step, reason, _changes} ->
              {:error, reason}
          end
        end
    end
  end

  def subscribe(_not_user, _plan, _cadence, _ip, _payment, _opts),
    do: {:error, :org_purchase_unsupported}

  # Post-commit side-effects of a subscribe: referral conversion, the pricing
  # audit, and the domain event (which drips the monthly allowance; the annual
  # path is suppressed there since its lump was granted in the transaction).
  defp after_subscribe(user, subscription, plan, cadence, ip_country, payment_country, opts) do
    if referrer_id = PerfectPaper.Referrals.referrer_id_for(user.id) do
      Credits.dispatch(:referral_purchase, %{referrer_id: referrer_id, referee_id: user.id})
    end

    _ =
      resolve_charge(
        user,
        plan,
        cadence,
        ip_country,
        payment_country,
        opts[:idempotency_key],
        opts
      )

    emit_subscription_updated(user.id, subscription)
  end

  defp upsert_subscription(user_id, attrs) do
    case get_subscription_for_user(user_id) do
      nil -> %Subscription{} |> Subscription.create_changeset(attrs) |> Repo.insert()
      existing -> existing |> Subscription.change_plan_changeset(attrs) |> Repo.update()
    end
  end

  defp emit_subscription_updated(user_id, %Subscription{} = subscription) do
    Events.emit(:"subscription.updated", %{
      organization_id: nil,
      actor_id: user_id,
      resource: %{type: :subscription, id: subscription.id},
      data: %{
        plan: subscription.plan,
        status: subscription.status,
        billing_period: subscription.billing_period
      }
    })
  end

  @doc """
  Starts a subscription purchase, dispatching on the provider's capability:

  - With a **hosted-checkout** provider (Stripe) → `{:ok, {:checkout, url}}`: the
    caller redirects the user to Stripe. The subscription is created
    asynchronously and confirmed by the `customer.subscription.*` webhook (see
    `process_stripe_webhook/2`) — never synchronously here.
  - With the **stub** (dev/test, no hosted UI) → falls back to the synchronous
    `subscribe/6` and returns `{:ok, {:subscribed, subscription}}`.

  `opts`: `:success_url`/`:cancel_url` (Stripe path), `:ip_country`/
  `:payment_country` (stub-path audit), `:req_opts` (test seam).
  """
  @spec start_checkout(User.t(), atom(), :monthly | :annual, keyword()) ::
          {:ok, {:checkout, String.t()} | {:subscribed, Subscription.t()}} | {:error, term()}
  def start_checkout(user, plan, cadence, opts \\ [])

  def start_checkout(%User{} = user, plan, cadence, opts) do
    if provider_supports?(:create_checkout_session, 1) do
      hosted_checkout(user, plan, cadence, opts)
    else
      with {:ok, sub} <-
             subscribe(user, plan, cadence, opts[:ip_country], opts[:payment_country], opts) do
        {:ok, {:subscribed, sub}}
      end
    end
  end

  def start_checkout(_user, _plan, _cadence, _opts), do: {:error, :org_purchase_unsupported}

  defp hosted_checkout(user, plan, cadence, opts) do
    with :ok <- checkout_guard(user, plan),
         {:ok, customer_id} <- get_or_create_customer(user, opts),
         {:ok, session} <-
           provider().create_checkout_session(%{
             provider_customer_id: customer_id,
             mode: "subscription",
             ui_mode: checkout_ui_mode(),
             plan: plan,
             cadence: cadence,
             success_url: opts[:success_url],
             cancel_url: opts[:cancel_url],
             return_url: opts[:success_url],
             metadata: %{user_id: user.id, plan: to_string(plan), cadence: to_string(cadence)},
             req_opts: opts[:req_opts]
           }) do
      {:ok, checkout_result(session)}
    end
  end

  # Hosted → redirect to {:checkout, url}; embedded → mount {:embedded, secret}.
  defp checkout_result(%{checkout_url: url}) when is_binary(url), do: {:checkout, url}
  defp checkout_result(%{client_secret: secret}) when is_binary(secret), do: {:embedded, secret}

  defp checkout_ui_mode do
    case :perfect_paper
         |> Application.get_env(:stripe, [])
         |> Keyword.get(:checkout_ui, :hosted) do
      :embedded -> "embedded"
      _ -> "hosted"
    end
  end

  @doc "The Stripe publishable key for client-side (embedded checkout / Elements)."
  @spec stripe_publishable_key() :: String.t() | nil
  def stripe_publishable_key,
    do: :perfect_paper |> Application.get_env(:stripe, []) |> Keyword.get(:publishable_key)

  # A fresh checkout session creates a NEW Stripe subscription, so guard the cases
  # that must NOT (they'd orphan or double-bill the existing one). Plan changes and
  # payment recovery go through the billing portal, not a second checkout.
  defp checkout_guard(user, plan) do
    case get_subscription_for_user(user.id) do
      nil -> :ok
      %Subscription{status: :canceled} -> :ok
      %Subscription{status: :active, plan: ^plan} -> {:error, :already_subscribed}
      %Subscription{status: :active} -> {:error, :change_plan_in_portal}
      %Subscription{status: :past_due} -> {:error, :recover_in_portal}
      _ -> :ok
    end
  end

  @doc """
  Returns the user's provider customer id — reusing the one on their existing
  subscription, or creating a fresh customer (with `user_id` in metadata so the
  webhook can map it back). A customerless user's id is **not** persisted here;
  the subscription webhook records it when the subscription is created.
  """
  @spec get_or_create_customer(User.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_or_create_customer(%User{} = user, opts \\ []) do
    case get_subscription_for_user(user.id) do
      %Subscription{provider_customer_id: cid} when is_binary(cid) ->
        {:ok, cid}

      _ ->
        with {:ok, %{provider_customer_id: cid}} <-
               provider().create_customer(%{
                 email: user.email,
                 user_id: user.id,
                 req_opts: opts[:req_opts]
               }) do
          {:ok, cid}
        end
    end
  end

  @doc """
  Whether the configured provider offers a self-service billing portal (Stripe
  does; the stub does not). Drives whether the "Manage billing" affordance shows.
  """
  @spec portal_supported?() :: boolean()
  def portal_supported?, do: provider_supports?(:create_portal_session, 1)

  # Whether the configured provider implements an optional callback. `ensure_loaded?`
  # first: `function_exported?/3` returns false for a not-yet-loaded module, which
  # would spuriously report the capability as absent before first use.
  defp provider_supports?(fun, arity) do
    mod = provider()
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end

  @doc """
  Creates a self-service billing-portal session for the user and returns its URL
  (the caller redirects). The portal is where the user cancels, updates their
  card, or switches plans — all reconciled back via the `customer.subscription.*`
  webhooks. Requires an existing provider customer (the user must have a
  subscription); otherwise `{:error, :no_customer}`.
  """
  @spec billing_portal_url(User.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :no_customer | :portal_unsupported | term()}
  def billing_portal_url(%User{} = user, return_url, opts \\ []) do
    cond do
      not portal_supported?() ->
        {:error, :portal_unsupported}

      true ->
        case get_subscription_for_user(user.id) do
          %Subscription{provider_customer_id: cid} when is_binary(cid) ->
            with {:ok, %{portal_url: url}} <-
                   provider().create_portal_session(%{
                     provider_customer_id: cid,
                     return_url: return_url,
                     req_opts: opts[:req_opts]
                   }) do
              {:ok, url}
            end

          _ ->
            {:error, :no_customer}
        end
    end
  end

  @doc """
  Starts a one-time credit-pack purchase, dispatching on provider capability:
  Stripe → `{:ok, {:checkout, url}}` (one-time `payment`-mode checkout; the credits
  are granted by the `checkout.session.completed` webhook); stub → grants
  synchronously and returns `{:ok, {:granted, reviews}}`.

  `reviews` is the bundle's credit count (1 credit = 1 full review), round-tripped
  through Stripe metadata so the webhook knows how many to grant.
  """
  @spec start_pack_checkout(User.t(), atom(), pos_integer(), keyword()) ::
          {:ok, {:checkout, String.t()} | {:granted, pos_integer()}} | {:error, term()}
  def start_pack_checkout(user, pack, reviews, opts \\ [])

  def start_pack_checkout(%User{} = user, pack, reviews, opts) do
    if provider_supports?(:create_checkout_session, 1) do
      with {:ok, customer_id} <- get_or_create_customer(user, opts),
           {:ok, %{checkout_url: url}} <-
             provider().create_checkout_session(%{
               provider_customer_id: customer_id,
               mode: "payment",
               plan: pack,
               cadence: nil,
               success_url: opts[:success_url],
               cancel_url: opts[:cancel_url],
               metadata: %{
                 user_id: user.id,
                 pack: to_string(pack),
                 credits: to_string(reviews)
               },
               req_opts: opts[:req_opts]
             }) do
        {:ok, {:checkout, url}}
      end
    else
      with {:ok, _} <- purchase_pack(user, pack, reviews, opts), do: {:ok, {:granted, reviews}}
    end
  end

  def start_pack_checkout(_user, _pack, _reviews, _opts), do: {:error, :org_purchase_unsupported}

  @doc """
  Synchronously records the pricing decision for a pack and grants its review
  credits (the stub/no-real-money path). Personal-path only.
  """
  @spec purchase_pack(User.t(), atom(), pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def purchase_pack(%User{} = user, pack, reviews, opts \\ []) do
    with {:ok, _result} <- resolve_charge(user, pack, :monthly, opts[:ip_country], nil, nil),
         {:ok, event} <- Credits.grant(user.id, reviews, "pack:#{pack}") do
      {:ok, event}
    end
  end

  @doc """
  Switches a subscription's billing period between `:monthly` and `:annual`.

  Does not call the payments provider — the period switch is recorded locally
  and is expected to be co-ordinated with the provider by the caller.
  """
  @spec set_billing_period(Subscription.t(), :monthly | :annual) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def set_billing_period(%Subscription{} = subscription, billing_period) do
    subscription
    |> Subscription.set_billing_period_changeset(billing_period)
    |> Repo.update()
  end

  @doc """
  Moves an existing subscription to a lower (or same) plan.

  Unlike `upgrade_plan/2`, this does not call the provider to create a new
  subscription — it updates the plan on the existing record only.
  """
  @spec downgrade_plan(struct(), atom()) :: {:ok, Subscription.t()} | {:error, term()}
  def downgrade_plan(user, plan) do
    case get_subscription_for_user(user.id) do
      nil ->
        {:error, :no_subscription}

      subscription ->
        result =
          subscription
          |> Subscription.change_plan_changeset(%{plan: plan})
          |> Repo.update()

        with {:ok, updated} <- result do
          _ = emit_subscription_updated(user.id, updated)
        end

        result
    end
  end

  # ── Canceling ─────────────────────────────────────────────────────────────

  @doc """
  Cancels a subscription — calls the provider to cancel upstream, then marks
  the local record as canceled.
  """
  @spec cancel_plan(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def cancel_plan(%Subscription{} = subscription) do
    with {:ok, _} <-
           provider().cancel_subscription(subscription.provider_subscription_id) do
      subscription
      |> Subscription.cancel_changeset()
      |> Repo.update()
    end
  end

  # ── Products ──────────────────────────────────────────────────────────────

  @doc "Returns the full product catalogue (plan, price, features)."
  @spec list_products() :: [Prices.product()]
  def list_products, do: Prices.list()

  # ── Transactional emails ────────────────────────────────────────────────────

  @doc "Confirms to a user that their subscription to `plan` is active."
  @spec send_subscription_confirmation(struct(), atom()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def send_subscription_confirmation(%{email: email}, plan) do
    Notifier.deliver_subscription_confirmation(email, plan, billing_url())
  end

  @doc "Sends a receipt for a successful payment of `amount_cents` on `plan`."
  @spec send_payment_receipt(struct(), integer(), atom()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def send_payment_receipt(%{email: email}, amount_cents, plan) do
    Notifier.deliver_payment_receipt(email, amount_cents, plan, billing_url())
  end

  @doc "Sends the dunning email when a payment fails on `plan`."
  @spec send_payment_failed(struct(), atom()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def send_payment_failed(%{email: email}, plan) do
    Notifier.deliver_payment_failed(email, plan, billing_url())
  end

  @doc "Confirms to a user that their `plan` subscription has been canceled."
  @spec send_subscription_canceled(struct(), atom()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def send_subscription_canceled(%{email: email}, plan) do
    Notifier.deliver_subscription_canceled(email, plan, billing_url())
  end

  # ── Enterprise Contracts ──────────────────────────────────────────────────

  @doc "Creates a draft enterprise contract. Internal/platform-admin gating is enforced at the web layer."
  @spec create_contract(PerfectPaper.Organizations.Organization.t(), map()) ::
          {:ok, Contract.t()} | {:error, Ecto.Changeset.t()}
  def create_contract(%{id: org_id}, attrs) do
    attrs = Map.put(attrs, :organization_id, org_id)

    with {:ok, contract} <- %Contract{} |> Contract.create_changeset(attrs) |> Repo.insert() do
      Events.emit(:"contract.created", %{
        organization_id: org_id,
        actor_id: attrs[:created_by],
        resource: %{type: :contract, id: contract.id},
        data: %{seats: contract.seats}
      })

      {:ok, contract}
    end
  end

  @doc "Activates a draft contract. Refuses a second active per org (partial unique index). (First invoice + funding wired in issue_invoice — Task 4.)"
  @spec activate_contract(Contract.t()) ::
          {:ok, Contract.t()} | {:error, :active_contract_exists | term()}
  def activate_contract(%Contract{} = contract) do
    changeset =
      Contract.status_changeset(
        %{contract | term_start: contract.term_start || Date.utc_today()},
        :active
      )

    case Repo.update(changeset) do
      {:ok, c} ->
        Events.emit(:"contract.activated", %{
          organization_id: c.organization_id,
          actor_id: nil,
          resource: %{type: :contract, id: c.id},
          data: %{seats: c.seats}
        })

        # Issue the first invoice + fund the pool. Activation still succeeds even
        # if invoicing errors (logged inside issue_invoice's caller path).
        _ = issue_invoice(c, c.term_start || Date.utc_today())
        {:ok, c}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :organization_id),
          do: {:error, :active_contract_exists},
          else: {:error, :invalid}
    end
  end

  @doc "Cancels a contract (stops future funding; pool balance unchanged)."
  @spec cancel_contract(Contract.t()) :: {:ok, Contract.t()} | {:error, term()}
  def cancel_contract(%Contract{} = contract),
    do: Repo.update(Contract.status_changeset(contract, :canceled))

  @doc "Atomic renewal: expire the old active contract and activate the new draft in one transaction (no zero-active window)."
  @spec swap_active_contract(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Contract.t()} | {:error, term()}
  def swap_active_contract(org_id, old_id, new_id) do
    Repo.transact(fn ->
      with {1, _} <-
             Repo.update_all(
               from(c in Contract,
                 where: c.id == ^old_id and c.organization_id == ^org_id and c.status == :active
               ),
               set: [status: :expired]
             ),
           new <- Repo.get_by!(Contract, id: new_id, organization_id: org_id),
           {:ok, activated} <-
             Repo.update(
               Contract.status_changeset(
                 %{new | term_start: new.term_start || Date.utc_today()},
                 :active
               )
             ) do
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

    Repo.exists?(
      from c in Contract,
        where:
          c.organization_id == ^org_id and c.status == :active and
            c.term_start <= ^today and c.term_end >= ^today
    )
  end

  @doc "Returns the org's date-aware active contract, or nil."
  @spec active_contract(Ecto.UUID.t()) :: Contract.t() | nil
  def active_contract(org_id) do
    today = Date.utc_today()

    Repo.one(
      from c in Contract,
        where:
          c.organization_id == ^org_id and c.status == :active and
            c.term_start <= ^today and c.term_end >= ^today,
        limit: 1
    )
  end

  @doc """
  Raises the active contract's `peak_seats_used` high-water mark to the org's
  current `:active` member count, computed inside a SINGLE atomic SQL statement
  (count + `GREATEST` in one `UPDATE`) so a concurrent bulk SCIM import cannot
  under-report the peak. Ignores orgs without an active contract. Called by
  `SeatTrackerServer` on `member.provisioned`/`member.reactivated` events.
  """
  @spec bump_peak_seats_for_event(Events.Event.t()) :: :ok
  def bump_peak_seats_for_event(%Events.Event{organization_id: org_id}) when is_binary(org_id) do
    Repo.update_all(
      from(c in Contract,
        where: c.organization_id == ^org_id and c.status == :active,
        update: [
          set: [
            peak_seats_used:
              fragment(
                "GREATEST(?, (SELECT count(*) FROM memberships WHERE organization_id = ? AND status = 'active'))",
                c.peak_seats_used,
                type(^org_id, :binary_id)
              )
          ]
        ]
      ),
      []
    )

    :ok
  end

  def bump_peak_seats_for_event(_), do: :ok

  @doc """
  The negative-pool soft floor for an org: `−(seats × per_seat_credits × 2)` (a
  2-period buffer) under a date-aware active contract, else `:none`. `Organizations`
  consults this only on the slow path (a draw that would push the pool negative).
  """
  @spec contract_floor(Ecto.UUID.t()) :: {:ok, integer()} | :none
  def contract_floor(org_id) do
    case active_contract(org_id) do
      %Contract{seats: s, per_seat_credits: c} -> {:ok, -(s * c * 2)}
      nil -> :none
    end
  end

  # ── Invoicing ────────────────────────────────────────────────────────────────

  @doc """
  Issues an invoice for the contract's current period and (in one transaction)
  atomically funds the pool by `funded_credits` and resets the high-water mark to
  the current active count. `billed_seats = seats + max(0, peak_seats_used − seats)`.
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
        with {:ok, invoice} <-
               insert_invoice_with_unique_number(%{
                 organization_id: contract.organization_id,
                 contract_id: contract.id,
                 period_start: period_start,
                 period_end: period_end,
                 seats_billed: contract.seats,
                 seat_overage: overage,
                 amount_cents: amount,
                 funded_credits: funded,
                 status: :issued,
                 issued_at: now,
                 due_at: DateTime.add(now, contract.net_terms_days * 86_400)
               }),
             :ok <- Organizations.fund_pool(contract.organization_id, funded),
             {_, _} <-
               Repo.update_all(from(c in Contract, where: c.id == ^contract.id),
                 set: [
                   peak_seats_used: Organizations.active_member_count(contract.organization_id),
                   last_funded_period: period_start
                 ]
               ) do
          {:ok, invoice}
        end
      end)

    with {:ok, invoice} <- result do
      Events.emit(:"invoice.issued", %{
        organization_id: contract.organization_id,
        actor_id: nil,
        resource: %{type: :invoice, id: invoice.id},
        data: %{number: invoice.number, amount_cents: amount}
      })

      {:ok, invoice}
    end
  end

  @doc "Marks an invoice paid (internal/platform-admin)."
  @spec mark_invoice_paid(Invoice.t()) :: {:ok, Invoice.t()} | {:error, term()}
  def mark_invoice_paid(%Invoice{} = invoice) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, paid} <- Repo.update(Invoice.status_changeset(invoice, :paid, now)) do
      Events.emit(:"invoice.paid", %{
        organization_id: paid.organization_id,
        actor_id: nil,
        resource: %{type: :invoice, id: paid.id},
        data: %{number: paid.number}
      })

      {:ok, paid}
    end
  end

  @doc """
  Voids an invoice AND claws back exactly its `funded_credits` from the pool
  (closes the issue→void free-credit loophole; the pool may go deeply negative).
  """
  @spec void_invoice(Invoice.t()) :: {:ok, Invoice.t()} | {:error, term()}
  # Idempotency guard: voiding an already-void invoice must NOT claw back the
  # funded credits a second time (a double-click / replayed POST would otherwise
  # drive the pool below the real debt).
  def void_invoice(%Invoice{status: :void}), do: {:error, :already_void}

  def void_invoice(%Invoice{} = invoice) do
    Repo.transact(fn ->
      # Atomic transition: only the call that actually flips a non-void invoice to
      # :void claws back the pool. Two concurrent voids holding the same stale
      # :issued struct therefore claw back exactly once — the struct guard above
      # only catches the sequential re-void of an already-:void struct.
      case Repo.update_all(
             from(i in Invoice, where: i.id == ^invoice.id and i.status != :void),
             set: [status: :void, updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
           ) do
        {1, _} ->
          :ok = Organizations.fund_pool(invoice.organization_id, -invoice.funded_credits)
          {:ok, %{invoice | status: :void}}

        {0, _} ->
          {:error, :already_void}
      end
    end)
  end

  @doc "The org's current contract (date-aware active first, else the latest by inserted_at)."
  @spec get_contract(Ecto.UUID.t()) :: Contract.t() | nil
  def get_contract(org_id) do
    active_contract(org_id) ||
      Repo.one(
        from c in Contract,
          where: c.organization_id == ^org_id,
          order_by: [desc: c.inserted_at],
          limit: 1
      )
  end

  @doc "Invoices for an org, newest first."
  @spec list_invoices(Ecto.UUID.t()) :: [Invoice.t()]
  def list_invoices(org_id),
    do:
      Repo.all(
        from i in Invoice, where: i.organization_id == ^org_id, order_by: [desc: i.issued_at]
      )

  @doc "Fetches one invoice scoped to its org (nil if none)."
  @spec get_invoice(Ecto.UUID.t(), Ecto.UUID.t()) :: Invoice.t() | nil
  def get_invoice(org_id, id) do
    # Guard a malformed (non-UUID) invoice id → nil (→ 404), never a CastError/500.
    if PerfectPaper.UUID.valid?(id),
      do: Repo.get_by(Invoice, id: id, organization_id: org_id),
      else: nil
  end

  @doc "Activates the org's most recent draft contract (the management surface has no contract id in the path)."
  @spec activate_latest_draft(Ecto.UUID.t()) ::
          {:ok, Contract.t()} | {:error, :not_found | :active_contract_exists | term()}
  def activate_latest_draft(org_id) do
    case Repo.one(
           from c in Contract,
             where: c.organization_id == ^org_id and c.status == :draft,
             order_by: [desc: c.inserted_at],
             limit: 1
         ) do
      nil -> {:error, :not_found}
      draft -> activate_contract(draft)
    end
  end

  # Period end for a billing interval.
  defp period_end_for(:monthly, start), do: Date.add(start, 30)
  defp period_end_for(:annual, start), do: Date.add(start, 365)

  # Inserts an invoice, regenerating a non-enumerable INV-YYYYMM-<base32> number on collision.
  defp insert_invoice_with_unique_number(attrs, attempts \\ 0) do
    number = invoice_number(attrs.period_start)

    case %Invoice{}
         |> Invoice.issue_changeset(Map.put(attrs, :number, number))
         |> Repo.insert() do
      {:ok, inv} ->
        {:ok, inv}

      {:error, %Ecto.Changeset{errors: errs}} = err ->
        if Keyword.has_key?(errs, :number) and attempts < 5,
          do: insert_invoice_with_unique_number(attrs, attempts + 1),
          else: err
    end
  end

  defp invoice_number(date) do
    ym = Calendar.strftime(date, "%Y%m")
    slug = :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false) |> binary_part(0, 8)
    "INV-#{ym}-#{slug}"
  end

  # ── Charge resolution (regional pricing) ──────────────────────────────────

  @doc """
  Resolves the **binding** price for a personal purchase and records the pricing
  decision for audit. Personal-path only — an org/group context is rejected with
  `{:error, :org_purchase_unsupported}` (org pool funding is never regionally
  adjusted; it charges via `issue_invoice`/`charge_pool`).

  The binding band is the **less generous** of the IP and payment-method countries
  (`Pricing.resolve_band/2`), so arbitrage by spoofing one signal yields no
  discount. On the stub, `payment_country` is `nil` → Band A for the binding
  number (display still shows the IP discount); Phase 2 supplies the real payment
  country and enforces the discount.

  Risk signals are looked up via the injected/configured `RiskSignals` adapter
  inside a telemetry span (flag-don't-block: any error → `:risk_unknown`, the
  purchase always proceeds). The decision is appended idempotently on
  `idempotency_key`. Returns the binding price; the subscription/order persistence
  + credit grant are performed by the caller's purchase path (`upgrade_plan` +
  `grant_*_allowance`), which Phase 2 will fold into this resolver's transaction.

  `opts`: `:ip` (raw IP for the risk lookup; only flags are persisted, never the
  IP), `:locale`, `:risk_signals` (adapter injection).
  """
  @spec resolve_charge(
          User.t(),
          atom(),
          :monthly | :annual,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def resolve_charge(
        user,
        product,
        cadence,
        ip_country,
        payment_country,
        idempotency_key,
        opts \\ []
      )

  def resolve_charge(%User{} = user, product, cadence, ip_country, payment_country, key, opts) do
    band = Pricing.resolve_band(ip_country, payment_country)

    case price_product(product, cadence, band) do
      {:ok, %{list_cents: list, applied_cents: applied, multiplier: mult}} ->
        signals = checked_risk_signals(opts[:ip], opts)

        decision = %{
          user_id: user.id,
          ip_country: ip_country,
          payment_country: payment_country,
          locale: opts[:locale],
          applied_band: band,
          product: to_string(product),
          cadence: to_string(cadence),
          list_cents: list,
          applied_cents: applied,
          applied_multiplier: mult,
          idempotency_key: key,
          signals: signals
        }

        with {:ok, audit} <- record_pricing_decision(decision) do
          {:ok,
           %{
             band: band,
             list_cents: list,
             applied_cents: applied,
             applied_multiplier: mult,
             signals: signals,
             audit: audit
           }}
        end

      :error ->
        {:error, :unknown_product}
    end
  end

  # Personal-path guard: anything that isn't a user (an org/group purchase) is
  # rejected — regional pricing never applies to org contracts.
  def resolve_charge(_not_a_user, _product, _cadence, _ip, _payment, _key, _opts) do
    {:error, :org_purchase_unsupported}
  end

  # Price a catalogue product at a resolved band → integer cents + multiplier bps.
  defp price_product(product, cadence, band) do
    cond do
      plan = Enum.find(Prices.subscriptions(), &(&1.key == product)) ->
        p = Pricing.price_for(plan, band)

        case cadence do
          :annual ->
            {:ok, %{list_cents: p.annual_list, applied_cents: p.annual_price, multiplier: p.bps}}

          _ ->
            {:ok,
             %{list_cents: p.monthly_list, applied_cents: p.monthly_price, multiplier: p.bps}}
        end

      pack = pack_or_single(product) ->
        p = Pricing.pack_price_for(pack, band)
        {:ok, %{list_cents: p.list, applied_cents: p.price, multiplier: p.bps}}

      true ->
        :error
    end
  end

  defp pack_or_single(:credit_single), do: Prices.credit_single()
  defp pack_or_single(product), do: Enum.find(Prices.credit_packs(), &(&1.key == product))

  # Look up risk signals inside a telemetry span so the external boundary's
  # latency + result are observable. Always returns a value the audit can store;
  # never blocks the purchase.
  defp checked_risk_signals(ip, opts) do
    :telemetry.span([:perfect_paper, :billing, :risk_signals], %{}, fn ->
      result = RiskSignals.check(ip, opts)
      outcome = if match?({:ok, _}, result), do: :ok, else: :risk_unknown
      {result, %{result: outcome}}
    end)
  end

  # ── Regional pricing audit ────────────────────────────────────────────────

  @doc """
  Appends one regional-pricing decision to the append-only audit log, computing
  the risk flags + score, and emits the `pricing_decision` telemetry event.

  Total on the happy path — never raises, never blocks a caller's transaction.
  The account-country snapshot + the new row are read+written under the same
  per-user advisory lock `Credits` uses, so the rapid-country-switch flag is
  reliable under concurrent purchases by the same user. Idempotent on
  `idempotency_key`: a retry returns the original decision rather than a 2nd row.

  `decision` is an atom-keyed map: `:user_id`, `:ip_country`, `:payment_country`,
  `:locale`, `:applied_band`, `:product`, `:cadence`, `:list_cents`,
  `:applied_cents`, `:applied_multiplier`, `:idempotency_key`, and `:signals`
  (`{:ok, %{vpn?, datacenter?}}` | `:risk_unknown`).
  """
  @spec record_pricing_decision(map()) :: {:ok, PricingAudit.t()} | {:error, term()}
  def record_pricing_decision(decision) when is_map(decision) do
    key = decision[:idempotency_key]

    # Sequential-retry fast path: a re-submitted decision returns the original
    # without re-entering the transaction (and without poisoning it on the unique
    # violation). The concurrent race is caught after the transaction below.
    case key && Repo.get_by(PricingAudit, idempotency_key: key) do
      %PricingAudit{} = existing -> {:ok, existing}
      _ -> insert_pricing_decision(decision, key)
    end
  end

  defp insert_pricing_decision(decision, key) do
    user_id = decision[:user_id]

    result =
      Repo.transact(fn ->
        if user_id, do: lock_user(user_id)
        history = prior_decision_countries(user_id)
        {mismatches, risk_score} = compute_risk(decision, history)
        signals = signals_map(decision[:signals])

        attrs =
          decision
          |> Map.take([
            :user_id,
            :ip_country,
            :payment_country,
            :locale,
            :product,
            :cadence,
            :list_cents,
            :applied_cents,
            :applied_multiplier,
            :idempotency_key
          ])
          |> Map.merge(%{
            applied_band: to_string(decision[:applied_band]),
            account_country_history: history,
            mismatches: mismatches,
            risk_score: risk_score,
            vpn?: signals[:vpn?],
            datacenter?: signals[:datacenter?]
          })

        case %PricingAudit{} |> PricingAudit.record_changeset(attrs) |> Repo.insert() do
          {:ok, audit} -> {:ok, audit}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, audit} ->
        emit_pricing_telemetry(audit)
        {:ok, audit}

      # Concurrent decision with the same key won the race — return the winner
      # (fetched outside the now-aborted transaction).
      {:error, %Ecto.Changeset{errors: [idempotency_key: _]}} when is_binary(key) ->
        {:ok, Repo.get_by!(PricingAudit, idempotency_key: key)}

      other ->
        other
    end
  end

  @doc """
  Lists pricing decisions for operator review or a user DSAR export.

  Filters: `:user_id` (the user-scoped DSAR accessor), `:flagged` (risk_score >
  0), `:since`/`:until` (`DateTime`). Newest first. The unfiltered/operator
  surface is platform-admin-gated at the web layer (PII + a movement profile).
  """
  @spec list_pricing_decisions(keyword()) :: [PricingAudit.t()]
  def list_pricing_decisions(filters \\ []) do
    base = from(a in PricingAudit, order_by: [desc: a.inserted_at])

    Enum.reduce(filters, base, fn
      {:user_id, id}, q -> from a in q, where: a.user_id == ^id
      {:flagged, true}, q -> from a in q, where: a.risk_score > 0
      {:since, dt}, q -> from a in q, where: a.inserted_at >= ^dt
      {:until, dt}, q -> from a in q, where: a.inserted_at <= ^dt
      _, q -> q
    end)
    |> Repo.all()
  end

  @doc """
  Anonymizes every pricing-decision row for a user (right-to-erasure / retention):
  nulls `user_id`, the countries, and `account_country_history`, keeping aggregate
  band/amount facts. Idempotent. Returns the number of rows affected.

  **Not** called from `Accounts.deactivate_user` — directory deprovisioning is not
  an erasure request, and anonymizing the fraud audit on every routine deprovision
  would destroy the anti-arbitrage record. Wire this into the dedicated erasure
  (DSAR) flow only.
  """
  @spec anonymize_pricing_audit(Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def anonymize_pricing_audit(user_id) do
    {count, _} =
      Repo.update_all(
        from(a in PricingAudit, where: a.user_id == ^user_id),
        set: [
          user_id: nil,
          ip_country: nil,
          payment_country: nil,
          account_country_history: [],
          idempotency_key: nil
        ]
      )

    {:ok, count}
  end

  @doc """
  Retention sweep: anonymizes every still-identified decision row older than
  `cutoff`, in **batches** (never one unbounded `UPDATE` over the append-only
  log). Loops until drained — already-anonymized rows (null `user_id`) are
  excluded, so the loop terminates. Returns the total rows anonymized. Driven by
  `Billing.PricingAuditAnonymizer` (Oban, `:maintenance`).
  """
  @spec anonymize_pricing_audits_before(DateTime.t(), pos_integer()) :: {:ok, non_neg_integer()}
  def anonymize_pricing_audits_before(cutoff, batch_size \\ 1_000) do
    anonymize_aged_batches(cutoff, batch_size, 0)
  end

  defp anonymize_aged_batches(cutoff, batch_size, acc) do
    ids =
      Repo.all(
        from a in PricingAudit,
          where: a.inserted_at < ^cutoff and not is_nil(a.user_id),
          select: a.id,
          limit: ^batch_size
      )

    case ids do
      [] ->
        {:ok, acc}

      _ ->
        {count, _} =
          Repo.update_all(
            from(a in PricingAudit, where: a.id in ^ids),
            set: [
              user_id: nil,
              ip_country: nil,
              payment_country: nil,
              account_country_history: [],
              idempotency_key: nil
            ]
          )

        anonymize_aged_batches(cutoff, batch_size, acc + count)
    end
  end

  # ── Stripe webhooks ───────────────────────────────────────────────────────

  @doc """
  Verifies, dedups, and reconciles one inbound provider webhook — the
  source-of-truth path for Stripe-driven subscription state.

  1. `verify_webhook/2` authenticates the raw body (bad sig → `:invalid_signature`).
  2. The event is **claimed** via `WebhookEvent` (unique `stripe_event_id`), so
     Stripe's at-least-once retries process exactly once (`:already_processed`).
  3. `translate_event/1` → reconcile into the local `Subscription` + credit grants.

  Returns `{:ok, :reconciled | :ignored | :already_processed}` or
  `{:error, :invalid_signature | term()}`. A processing error leaves the event
  un-`processed` so a Stripe retry re-claims and reprocesses it.
  """
  @spec process_stripe_webhook(binary(), binary()) ::
          {:ok, :reconciled | :ignored | :already_processed} | {:error, term()}
  def process_stripe_webhook(raw_body, signature) do
    with {:ok, raw} <- provider().verify_webhook(raw_body, signature),
         {:ok, claim} <- claim_webhook_event(raw) do
      case claim do
        :already_processed -> {:ok, :already_processed}
        {:claimed, webhook_event} -> finalize_webhook(webhook_event, reconcile_stripe_event(raw))
      end
    end
  end

  # Atomic dedup: an existing processed row → skip; an existing unprocessed/errored
  # row → re-claim (retry); otherwise insert, treating a unique-violation race as
  # already-claimed.
  defp claim_webhook_event(%{"id" => id, "type" => type}) do
    case Repo.get_by(WebhookEvent, stripe_event_id: id) do
      %WebhookEvent{processed: true} ->
        {:ok, :already_processed}

      %WebhookEvent{} = existing ->
        {:ok, {:claimed, existing}}

      nil ->
        case WebhookEvent.claim_changeset(%{stripe_event_id: id, event_type: type})
             |> Repo.insert() do
          {:ok, event} -> {:ok, {:claimed, event}}
          {:error, %Ecto.Changeset{errors: [stripe_event_id: _]}} -> {:ok, :already_processed}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp claim_webhook_event(_), do: {:error, :malformed_event}

  defp reconcile_stripe_event(raw) do
    case provider().translate_event(raw) do
      {:ok, %{action: action, data: data}} -> apply_stripe_action(action, data)
      {:error, :unhandled_event} -> {:ok, :ignored}
    end
  end

  # Upsert the user's subscription from Stripe, then settle entitlement: monthly is
  # dripped by the emitted event; annual gets its lump (idempotent per term).
  defp apply_stripe_action(:subscription_upserted, %{user_id: user_id} = data)
       when is_binary(user_id) do
    attrs = %{
      user_id: user_id,
      plan: data.plan,
      status: data.status,
      billing_period: data.billing_period,
      provider_customer_id: data.provider_customer_id,
      provider_subscription_id: data.provider_subscription_id,
      current_period_end: data.current_period_end
    }

    existing =
      Repo.get_by(Subscription, provider_subscription_id: data.provider_subscription_id) ||
        get_subscription_for_user(user_id)

    changeset =
      case existing do
        nil -> Subscription.sync_changeset(%Subscription{}, attrs)
        sub -> Subscription.sync_changeset(sub, attrs)
      end

    with {:ok, subscription} <- (existing && Repo.update(changeset)) || Repo.insert(changeset) do
      if subscription.status == :active and subscription.billing_period == :annual do
        Credits.grant_annual_allowance(user_id, subscription.plan,
          subscription_id: subscription.id
        )
      end

      emit_subscription_updated(user_id, subscription)
      {:ok, :reconciled}
    end
  end

  defp apply_stripe_action(:subscription_upserted, _data), do: {:error, :missing_user_metadata}

  defp apply_stripe_action(:subscription_canceled, %{provider_subscription_id: sub_id}) do
    case Repo.get_by(Subscription, provider_subscription_id: sub_id) do
      nil ->
        {:ok, :ignored}

      sub ->
        with {:ok, _} <- sub |> Subscription.cancel_changeset() |> Repo.update(),
             do: {:ok, :reconciled}
    end
  end

  # A one-time pack purchase: grant the bundle's review credits. Exactly-once is
  # guaranteed by the WebhookEvent dedup (this event id processes once); the reason
  # carries the pack for traceability.
  defp apply_stripe_action(:checkout_completed, %{mode: "payment", metadata: meta})
       when is_map(meta) do
    with user_id when is_binary(user_id) <- meta["user_id"],
         {credits, ""} when credits > 0 <- Integer.parse(to_string(meta["credits"])) do
      with {:ok, _event} <- Credits.grant(user_id, credits, "stripe_pack:#{meta["pack"]}") do
        {:ok, :reconciled}
      end
    else
      _ -> {:ok, :ignored}
    end
  end

  # A subscription-mode checkout is informational here — the subscription.created
  # event does the real upsert (and the success page reacts to subscription.updated).
  defp apply_stripe_action(:checkout_completed, _data), do: {:ok, :ignored}

  defp finalize_webhook(webhook_event, {:ok, status}) do
    {:ok, _} = webhook_event |> WebhookEvent.processed_changeset() |> Repo.update()
    {:ok, status}
  end

  defp finalize_webhook(webhook_event, {:error, reason}) do
    {:ok, _} = webhook_event |> WebhookEvent.error_changeset(inspect(reason)) |> Repo.update()
    {:error, reason}
  end

  # ── Private ───────────────────────────────────────────────────────────────

  # Distinct prior IP countries for the user — a point-in-time snapshot of the
  # account's movement, read just before appending the new decision.
  defp prior_decision_countries(nil), do: []

  defp prior_decision_countries(user_id) do
    Repo.all(
      from a in PricingAudit,
        where: a.user_id == ^user_id and not is_nil(a.ip_country),
        distinct: true,
        select: a.ip_country
    )
  end

  # Flag-don't-block risk signals: band mismatch (spoofed IP vs payment country),
  # VPN/datacenter, and a country switch vs the account's prior countries. The
  # score is the flag count; any flag (> 0) marks the decision for review.
  defp compute_risk(decision, history) do
    signals = signals_map(decision[:signals])

    mismatches =
      []
      |> flag(band_mismatch?(decision), "band_mismatch")
      |> flag(signals[:vpn?] == true, "vpn")
      |> flag(signals[:datacenter?] == true, "datacenter")
      |> flag(country_switch?(decision[:ip_country], history), "country_switch")
      |> Enum.reverse()

    {mismatches, length(mismatches)}
  end

  defp flag(acc, true, label), do: [label | acc]
  defp flag(acc, _false, _label), do: acc

  # The IP and payment-method countries resolve to different bands → possible
  # arbitrage. Only when both countries are present.
  defp band_mismatch?(%{ip_country: ip, payment_country: pay})
       when is_binary(ip) and is_binary(pay) do
    Pricing.country_band(ip) != Pricing.country_band(pay)
  end

  defp band_mismatch?(_), do: false

  defp country_switch?(ip, history) when is_binary(ip),
    do: history != [] and ip not in history

  defp country_switch?(_ip, _history), do: false

  # Normalize the RiskSignals result into a plain flags map (risk_unknown → false).
  defp signals_map({:ok, %{} = signals}), do: signals
  defp signals_map(_), do: %{vpn?: false, datacenter?: false}

  defp emit_pricing_telemetry(%PricingAudit{} = audit) do
    :telemetry.execute(
      [:perfect_paper, :billing, :pricing_decision],
      %{list_cents: audit.list_cents || 0, applied_cents: audit.applied_cents || 0},
      %{
        applied_band: audit.applied_band,
        product: audit.product,
        cadence: audit.cadence,
        mismatch?: audit.mismatches != [],
        risk_score: audit.risk_score || 0
      }
    )
  end

  # Serialize per-user audit writes inside the current transaction (same lock
  # Credits uses), so the read-history-then-append is atomic for the switch flag.
  defp lock_user(user_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [user_id])
    :ok
  end

  defp billing_url, do: PerfectPaperWeb.Endpoint.url() <> "/billing"

  defp provider do
    Application.get_env(:perfect_paper, :billing_provider)
  end
end
