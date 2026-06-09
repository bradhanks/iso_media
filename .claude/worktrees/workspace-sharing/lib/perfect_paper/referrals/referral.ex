defmodule PerfectPaper.Referrals.Referral do
  @moduledoc """
  A referral record linking a referrer to a referee via a unique code.
  Tracks the lifecycle from initial registration through payment and reward
  issuance.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "referrals" do
    field :referral_code, :string
    field :referrer_user_id, :binary_id
    field :referee_user_id, :binary_id
    field :first_payment_at, :utc_datetime
    field :rewards_issued_at, :utc_datetime
    field :status, Ecto.Enum, values: [:pending, :accepted, :rewarded], default: :pending

    timestamps(type: :utc_datetime)
  end

  @doc "Builds a changeset for registering a new referral."
  @spec register_changeset(t(), map()) :: Ecto.Changeset.t()
  def register_changeset(referral, attrs) do
    referral
    |> cast(attrs, [:referrer_user_id, :referral_code, :referee_user_id])
    |> validate_required([:referrer_user_id, :referral_code])
    |> unique_constraint(:referral_code)
  end

  @doc "Claims an unclaimed referral for a referee (sets referee + :accepted)."
  @spec accept_changeset(t(), map()) :: Ecto.Changeset.t()
  def accept_changeset(referral, attrs) do
    referral
    |> cast(attrs, [:referee_user_id, :status])
    |> validate_required([:referee_user_id])
  end
end
