defmodule PerfectPaper.Events.Event do
  @moduledoc "A domain event envelope. Transient (not persisted by Events); validated before publish."
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(session.completed comment.added comment.addressed comment.dismissed session.shared subscription.updated credits.low document.converted document.conversion_failed member.provisioned member.deactivated member.reactivated group.synced contract.created contract.activated invoice.issued invoice.paid)a

  @type t :: %__MODULE__{}
  @primary_key false
  embedded_schema do
    field :id, :binary_id
    field :type, Ecto.Enum, values: @types
    field :occurred_at, :utc_datetime_usec
    field :organization_id, :binary_id
    field :actor_id, :binary_id
    field :resource, :map
    field :data, :map, default: %{}
  end

  @doc "Validates an event envelope."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:id, :type, :occurred_at, :organization_id, :actor_id, :resource, :data])
    |> validate_required([:type])
  end

  @doc "All known event types."
  @spec types() :: [atom()]
  def types, do: @types
end
