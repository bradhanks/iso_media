defmodule PerfectPaper.Authz.ResourceGrant do
  @moduledoc """
  A grant attaching a role to a subject (a user or a group) on a specific
  resource — the sharing primitive. Read by the policy engine; created by the
  invite/sharing flow (a later spec).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "resource_grants" do
    field :resource_type, Ecto.Enum, values: [:session]
    field :resource_id, :binary_id
    field :subject_type, Ecto.Enum, values: [:user, :group]
    field :subject_id, :binary_id
    field :role, Ecto.Enum, values: [:viewer, :commenter, :editor, :admin, :owner]
    field :granted_by, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a resource grant."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(grant, attrs) do
    grant
    |> cast(attrs, [:resource_type, :resource_id, :subject_type, :subject_id, :role, :granted_by])
    |> validate_required([:resource_type, :resource_id, :subject_type, :subject_id, :role])
    |> unique_constraint([:resource_type, :resource_id, :subject_type, :subject_id],
      name: :resource_grants_unique_index
    )
  end
end
