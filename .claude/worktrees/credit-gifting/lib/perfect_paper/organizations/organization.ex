defmodule PerfectPaper.Organizations.Organization do
  @moduledoc """
  An organization groups users under a shared credit pool. The owner controls
  the pool and may allocate credits to members.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Organizations.Membership

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organizations" do
    field :name, :string
    field :credit_pool, :integer, default: 0
    field :owner_id, :binary_id
    field :mfa_required, :boolean, default: false

    has_many :memberships, Membership

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new organization."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :credit_pool, :owner_id, :mfa_required])
    |> validate_required([:name, :owner_id])
    |> validate_number(:credit_pool, greater_than_or_equal_to: 0)
  end

  @doc "Changeset for adjusting the organization's credit pool."
  @spec pool_changeset(t(), map()) :: Ecto.Changeset.t()
  def pool_changeset(org, attrs) do
    org
    |> cast(attrs, [:credit_pool])
    |> validate_number(:credit_pool, greater_than_or_equal_to: 0)
  end
end
