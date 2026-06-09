defmodule PerfectPaper.Organizations.GroupMembership do
  @moduledoc """
  A user's role at a node in an organization's group tree. Roles inherit *down*
  the tree: a role here applies to resources owned by this group or any descendant.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Organizations.Group

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_memberships" do
    field :role, Ecto.Enum,
      values: [:viewer, :commenter, :editor, :admin, :owner],
      default: :viewer

    field :user_id, :binary_id

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for adding a user to a group with a role."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :group_id, :user_id])
    |> validate_required([:group_id, :user_id])
    |> unique_constraint([:group_id, :user_id])
  end
end
