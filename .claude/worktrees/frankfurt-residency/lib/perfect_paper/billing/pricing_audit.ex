defmodule PerfectPaper.Billing.PricingAudit do
  @moduledoc """
  An append-only record of one regional-pricing decision, for after-the-fact
  arbitrage scrutiny.

  **Decision facts are immutable** — country/band/cents/cadence are written once
  (`inserted_at` only, no `updated_at`). The **risk columns** (`vpn?`,
  `datacenter?`, `risk_score`) are nullable and *set-once*: written synchronously
  at insert, or enriched exactly once by a deferred Oban job via an
  `IS NULL`-guarded update. `account_country_history` is a point-in-time snapshot
  of the account's prior decision countries, not a maintained list.

  Privacy (GDPR): only **country codes** are stored, never the raw IP — the
  `RiskSignals` adapter receives the IP and returns flags; only the flags +
  country are persisted. Rows are anonymized after a retention window
  (`Billing.anonymize_pricing_audit/1`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          ip_country: String.t() | nil,
          payment_country: String.t() | nil,
          locale: String.t() | nil,
          applied_band: String.t() | nil,
          product: String.t() | nil,
          cadence: String.t() | nil,
          list_cents: non_neg_integer() | nil,
          applied_cents: non_neg_integer() | nil,
          applied_multiplier: non_neg_integer() | nil,
          idempotency_key: String.t() | nil,
          vpn?: boolean() | nil,
          datacenter?: boolean() | nil,
          risk_score: integer() | nil,
          account_country_history: [String.t()],
          mismatches: [String.t()],
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pricing_audits" do
    field :user_id, :binary_id
    field :ip_country, :string
    field :payment_country, :string
    field :locale, :string
    field :applied_band, :string
    field :product, :string
    field :cadence, :string
    field :list_cents, :integer
    field :applied_cents, :integer
    field :applied_multiplier, :integer
    field :idempotency_key, :string
    field :vpn?, :boolean
    field :datacenter?, :boolean
    field :risk_score, :integer
    field :account_country_history, {:array, :string}, default: []
    field :mismatches, {:array, :string}, default: []

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for appending a pricing decision. All amounts are server-computed."
  @spec record_changeset(t(), map()) :: Ecto.Changeset.t()
  def record_changeset(audit, attrs) do
    audit
    |> cast(attrs, [
      :user_id,
      :ip_country,
      :payment_country,
      :locale,
      :applied_band,
      :product,
      :cadence,
      :list_cents,
      :applied_cents,
      :applied_multiplier,
      :idempotency_key,
      :vpn?,
      :datacenter?,
      :risk_score,
      :account_country_history,
      :mismatches
    ])
    |> validate_required([:applied_band, :product, :applied_cents, :applied_multiplier])
    |> unique_constraint(:idempotency_key)
  end

  @doc """
  Changeset that anonymizes a decision row for retention/erasure: nulls the
  identifying + movement-profile fields, keeping the aggregate band/amount facts
  for analytics. Idempotent — re-anonymizing a row is a no-op.
  """
  @spec anonymize_changeset(t()) :: Ecto.Changeset.t()
  def anonymize_changeset(audit) do
    audit
    |> change(%{
      user_id: nil,
      ip_country: nil,
      payment_country: nil,
      account_country_history: [],
      idempotency_key: nil
    })
  end
end
