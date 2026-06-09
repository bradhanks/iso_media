defmodule PerfectPaper.Billing.WebhookEvent do
  @moduledoc """
  Idempotency record for one inbound provider (Stripe) webhook.

  Keyed on the provider's `stripe_event_id` (unique) so processing is
  exactly-once under Stripe's at-least-once retry delivery: a claim insert that
  hits the unique constraint means the event is already being / has been handled.
  `processed` flips true on success; `error` records a failure for retry/inspection.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          stripe_event_id: String.t() | nil,
          event_type: String.t() | nil,
          processed: boolean(),
          error: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "webhook_events" do
    field :stripe_event_id, :string
    field :event_type, :string
    field :processed, :boolean, default: false
    field :error, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset that claims an event id (unique-constrained dedup)."
  @spec claim_changeset(map()) :: Ecto.Changeset.t()
  def claim_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:stripe_event_id, :event_type])
    |> validate_required([:stripe_event_id])
    |> unique_constraint(:stripe_event_id)
  end

  @doc "Marks the event processed and clears any prior error."
  @spec processed_changeset(t()) :: Ecto.Changeset.t()
  def processed_changeset(event), do: change(event, processed: true, error: nil)

  @doc "Records a processing error (leaves processed false for retry)."
  @spec error_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def error_changeset(event, reason), do: change(event, processed: false, error: reason)
end
