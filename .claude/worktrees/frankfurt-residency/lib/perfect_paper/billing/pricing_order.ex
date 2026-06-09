defmodule PerfectPaper.Billing.PricingOrder do
  @moduledoc "Idempotency record for a banded product purchase. One row per idempotency key; the unique constraint is the dedup mechanism."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          idempotency_key: String.t() | nil,
          product: String.t() | nil,
          cadence: String.t() | nil,
          applied_band: String.t() | nil,
          applied_cents: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "pricing_orders" do
    field :user_id, :binary_id
    field :idempotency_key, :string
    field :product, :string
    field :cadence, :string
    field :applied_band, :string
    field :applied_cents, :integer
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a new pricing order row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(order \\ %__MODULE__{}, attrs) do
    order
    |> cast(attrs, [:user_id, :idempotency_key, :product, :cadence, :applied_band, :applied_cents])
    |> validate_required([
      :user_id,
      :idempotency_key,
      :product,
      :cadence,
      :applied_band,
      :applied_cents
    ])
    |> unique_constraint(:idempotency_key)
  end
end
