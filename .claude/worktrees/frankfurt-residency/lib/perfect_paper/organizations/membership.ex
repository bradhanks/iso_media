defmodule PerfectPaper.Organizations.Membership do
  @moduledoc """
  A user's membership in an organization, carrying their role and how many
  credits have been allocated to them from the organization's pool.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Organizations.Organization

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          role: :owner | :admin | :member,
          allocated_credits: integer(),
          status: :active | :deactivated,
          deactivated_at: DateTime.t() | nil,
          user_id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          organization:
            PerfectPaper.Organizations.Organization.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "memberships" do
    field :role, Ecto.Enum, values: [:owner, :admin, :member], default: :member
    field :allocated_credits, :integer, default: 0
    field :status, Ecto.Enum, values: [:active, :deactivated], default: :active
    field :deactivated_at, :utc_datetime
    field :user_id, :binary_id

    belongs_to :organization, Organization

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for adding a new member to an organization."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :allocated_credits, :organization_id, :user_id])
    |> validate_required([:organization_id, :user_id])
    |> unique_constraint([:organization_id, :user_id])
  end

  @doc "Changeset for adjusting a member's allocated credits."
  @spec allocation_changeset(t(), map()) :: Ecto.Changeset.t()
  def allocation_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:allocated_credits])
    |> validate_number(:allocated_credits, greater_than_or_equal_to: 0)
  end

  @doc "Changeset for activating/deactivating a membership."
  @spec status_changeset(t(), :active | :deactivated) :: Ecto.Changeset.t()
  def status_changeset(membership, :deactivated) do
    change(membership,
      status: :deactivated,
      deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  def status_changeset(membership, :active) do
    change(membership, status: :active, deactivated_at: nil)
  end
end
