defmodule PerfectPaper.Repo.Migrations.CreateWebhookEvents do
  use Ecto.Migration

  # Idempotency ledger for inbound provider (Stripe) webhooks. The unique
  # stripe_event_id makes processing exactly-once under at-least-once delivery:
  # a retried event hits the constraint and is recognized as already-claimed.
  def change do
    create table(:webhook_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :stripe_event_id, :string, null: false
      add :event_type, :string
      add :processed, :boolean, null: false, default: false
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:webhook_events, [:stripe_event_id])
  end
end
