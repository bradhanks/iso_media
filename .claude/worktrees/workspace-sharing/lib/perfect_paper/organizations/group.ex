defmodule PerfectPaper.Organizations.Group do
  @moduledoc """
  A node in an organization's group tree (college → department → lab → team).

  `path` is an ltree materialized path of ancestor group ids (hyphens stripped),
  stored as text and queried via `path::ltree`. The context maintains it; it is
  never cast from user input.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Organizations.Organization

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "groups" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:college, :department, :team, :lab, :group], default: :group
    field :path, :string
    field :parent_id, :binary_id
    field :scim_managed, :boolean, default: false
    field :scim_external_id, :string

    belongs_to :organization, Organization

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a group. `path` is computed by the context."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(group, attrs) do
    group
    |> cast(attrs, [
      :id,
      :name,
      :kind,
      :path,
      :parent_id,
      :organization_id,
      :scim_managed,
      :scim_external_id
    ])
    |> validate_required([:organization_id, :name, :path])
  end

  @doc "Changeset for renaming/updating a group's mutable attributes."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end
