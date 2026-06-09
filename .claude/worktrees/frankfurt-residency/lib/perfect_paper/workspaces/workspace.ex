defmodule PerfectPaper.Workspaces.Workspace do
  @moduledoc """
  A workspace: a lightweight, user-owned container that groups a user's reviews.
  Distinct from the enterprise `Organizations` tenant. Each user has exactly one
  Personal workspace (`is_personal: true`) plus any they create.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Accounts.User

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workspaces" do
    field :name, :string
    field :is_personal, :boolean, default: false
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a user-created workspace."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :user_id])
    |> update_change(:name, &trim/1)
    |> validate_required([:name, :user_id])
    |> validate_length(:name, min: 1, max: 120)
  end

  @doc "Changeset for the user's auto-created Personal workspace."
  @spec personal_changeset(User.t()) :: Ecto.Changeset.t()
  def personal_changeset(%User{id: user_id}) do
    %__MODULE__{}
    |> cast(%{name: "Personal", user_id: user_id, is_personal: true}, [
      :name,
      :user_id,
      :is_personal
    ])
    |> validate_required([:name, :user_id])
    # Map the partial unique index so a racing second insert returns
    # {:error, changeset} (which Workspaces.insert_personal/1 recovers from)
    # instead of raising Ecto.ConstraintError.
    |> unique_constraint(:user_id, name: :workspaces_one_personal_per_user)
  end

  @doc "Changeset for renaming a workspace."
  @spec rename_changeset(t(), map()) :: Ecto.Changeset.t()
  def rename_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name])
    |> update_change(:name, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
