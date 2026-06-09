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
      :organization_id,
      :contract_id,
      :number,
      :period_start,
      :period_end,
      :seats_billed,
      :seat_overage,
      :amount_cents,
      :funded_credits,
      :status,
      :issued_at,
      :due_at
    ])
    |> validate_required([
      :organization_id,
      :contract_id,
      :number,
      :period_start,
      :period_end,
      :seats_billed,
      :amount_cents,
      :issued_at,
      :due_at
    ])
    |> unique_constraint(:number)
    |> unique_constraint([:contract_id, :period_start],
      name: :invoices_contract_id_period_start_index
    )
  end

  @doc "Changeset for a status transition (:paid sets paid_at; :void/:overdue do not)."
  @spec status_changeset(t(), :paid | :void | :overdue, DateTime.t() | nil) :: Ecto.Changeset.t()
  def status_changeset(invoice, :paid, paid_at),
    do: change(invoice, status: :paid, paid_at: paid_at)

  def status_changeset(invoice, status, _), do: change(invoice, status: status)
end
