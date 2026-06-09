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
      :organization_id,
      :seats,
      :price_per_seat_cents,
      :per_seat_credits,
      :interval,
      :term_start,
      :term_end,
      :po_number,
      :net_terms_days,
      :created_by
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
