defmodule PerfectPaper.Authz.Decision do
  @moduledoc """
  An append-only audit record of an authorization decision on a mutating action
  (`:edit`, `:delete`, `:share`, `:manage_members`). Reads are not logged in
  Spec 1. Best-effort: writing it never alters the decision it records.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "authz_decisions" do
    field :subject_id, :binary_id
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :decision, :string
    field :reason, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset for an audit row."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(decision, attrs) do
    decision
    |> cast(attrs, [:subject_id, :action, :resource_type, :resource_id, :decision, :reason])
    |> validate_required([:action, :resource_type, :decision])
  end
end
