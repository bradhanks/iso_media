defmodule PerfectPaper.Billing.Subscription do
  @moduledoc """
  A user's billing subscription: their current plan, payment status, and the
  provider identifiers needed to manage it with an upstream payments provider.

  One subscription per user (unique constraint on user_id). The plan and status
  are stored as strings via `Ecto.Enum`; all enum keys are atoms in Elixir.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          plan: :starter | :professional | :advanced | nil,
          status: :active | :canceled | :past_due | nil,
          billing_period: :monthly | :annual,
          applied_band: String.t() | nil,
          applied_cents: non_neg_integer() | nil,
          provider_customer_id: String.t() | nil,
          provider_subscription_id: String.t() | nil,
          current_period_end: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "subscriptions" do
    field :plan, Ecto.Enum, values: [:starter, :professional, :advanced]
    field :status, Ecto.Enum, values: [:active, :canceled, :past_due], default: :active
    field :billing_period, Ecto.Enum, values: [:monthly, :annual], default: :monthly
    field :applied_band, :string
    field :applied_cents, :integer
    field :provider_customer_id, :string
    field :provider_subscription_id, :string
    field :current_period_end, :utc_datetime
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new subscription record."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :plan,
      :status,
      :billing_period,
      :applied_band,
      :applied_cents,
      :provider_customer_id,
      :provider_subscription_id,
      :current_period_end
    ])
    |> validate_required([:user_id, :plan])
    |> unique_constraint(:user_id)
  end

  @doc "Changeset for updating the plan on an existing subscription."
  @spec change_plan_changeset(t(), map()) :: Ecto.Changeset.t()
  def change_plan_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :plan,
      :billing_period,
      :applied_band,
      :applied_cents,
      :provider_customer_id,
      :provider_subscription_id,
      :current_period_end
    ])
    |> validate_required([:plan])
  end

  @doc """
  Changeset for syncing a subscription from a provider webhook — casts the full
  provider-driven field set (including `:status`, which `change_plan_changeset`
  deliberately omits) so a `past_due`/`canceled` transition from Stripe lands.
  """
  @spec sync_changeset(t(), map()) :: Ecto.Changeset.t()
  def sync_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :plan,
      :status,
      :billing_period,
      :applied_band,
      :applied_cents,
      :provider_customer_id,
      :provider_subscription_id,
      :current_period_end
    ])
    |> validate_required([:user_id, :plan])
    |> unique_constraint(:user_id)
  end

  @doc "Changeset for switching the billing period (monthly ↔ annual)."
  @spec set_billing_period_changeset(t(), :monthly | :annual) :: Ecto.Changeset.t()
  def set_billing_period_changeset(subscription, billing_period) do
    subscription
    |> cast(%{billing_period: billing_period}, [:billing_period])
    |> validate_required([:billing_period])
  end

  @doc "Changeset that marks a subscription as canceled."
  @spec cancel_changeset(t()) :: Ecto.Changeset.t()
  def cancel_changeset(subscription) do
    subscription
    |> change()
    |> put_change(:status, :canceled)
  end

  # ── Pure predicates / display helpers (borrowed from the Credo billing model) ──

  @doc "True when the subscription is currently active (billing in good standing)."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: :active}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "True when the subscription is past due on payment."
  @spec past_due?(t()) :: boolean()
  def past_due?(%__MODULE__{status: :past_due}), do: true
  def past_due?(%__MODULE__{}), do: false

  @doc "True when the subscription has been canceled."
  @spec canceled?(t()) :: boolean()
  def canceled?(%__MODULE__{status: :canceled}), do: true
  def canceled?(%__MODULE__{}), do: false

  @doc "True when there is no paid subscription — i.e. the user is on free previews."
  @spec free?(t() | nil) :: boolean()
  def free?(nil), do: true
  def free?(%__MODULE__{}), do: false

  @doc "Human-friendly status label for display in the UI."
  @spec status_label(t()) :: String.t()
  def status_label(%__MODULE__{status: :active}), do: "Active"
  def status_label(%__MODULE__{status: :past_due}), do: "Past due"
  def status_label(%__MODULE__{status: :canceled}), do: "Canceled"

  @doc "Human-friendly plan label for display in the UI."
  @spec plan_label(t()) :: String.t()
  def plan_label(%__MODULE__{plan: plan}), do: plan |> Atom.to_string() |> String.capitalize()
end
