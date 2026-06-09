defmodule PerfectPaper.Credits.CreditEvent do
  @moduledoc """
  An individual ledger entry in the credits system.

  Positive `amount` = credits granted; negative `amount` = credits charged.
  The table is append-only: events are never updated or deleted (only cascade-
  deleted when the parent user is removed).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_events" do
    field :user_id, :binary_id
    field :amount, :integer
    field :reason, :string
    field :kind, Ecto.Enum, values: [:paid, :preview], default: :paid
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for inserting a new credit ledger entry."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(event, attrs) do
    event
    |> cast(attrs, [:user_id, :amount, :reason, :kind, :metadata])
    |> validate_required([:user_id, :amount, :reason, :kind])
  end
end
