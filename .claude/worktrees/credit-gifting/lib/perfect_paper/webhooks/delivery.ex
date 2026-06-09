defmodule PerfectPaper.Webhooks.Delivery do
  @moduledoc """
  A webhook delivery log entry: records each attempt to deliver an event to a
  `Webhooks.Endpoint`. Deliveries are append-only in concept; the `attempt_changeset`
  updates status and attempt metadata as dispatch progresses.

  Status transitions: pending → delivered | failed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :delivered | :failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          endpoint_id: Ecto.UUID.t() | nil,
          event_type: String.t() | nil,
          event_id: Ecto.UUID.t() | nil,
          payload: map(),
          status: status(),
          attempts: non_neg_integer(),
          response_status: integer() | nil,
          last_error: String.t() | nil,
          delivered_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webhook_deliveries" do
    field :endpoint_id, :binary_id
    field :event_type, :string
    field :event_id, :binary_id
    field :payload, :map, default: %{}
    field :status, Ecto.Enum, values: [:pending, :delivered, :failed], default: :pending
    field :attempts, :integer, default: 0
    field :response_status, :integer
    field :last_error, :string
    field :delivered_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new delivery record (before dispatch begins).
  Requires endpoint_id and event_type; payload and event_id are optional.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = delivery, attrs) do
    delivery
    |> cast(attrs, [:endpoint_id, :event_type, :event_id, :payload])
    |> validate_required([:endpoint_id, :event_type])
    |> unique_constraint([:endpoint_id, :event_id],
      name: :webhook_deliveries_endpoint_event_uidx
    )
  end

  @doc """
  Changeset applied after a delivery attempt. Updates status, attempt counter,
  HTTP response_status, last_error, and delivered_at timestamp.
  """
  @spec attempt_changeset(t(), map()) :: Ecto.Changeset.t()
  def attempt_changeset(%__MODULE__{} = delivery, attrs) do
    delivery
    |> cast(attrs, [:status, :attempts, :response_status, :last_error, :delivered_at])
  end
end
