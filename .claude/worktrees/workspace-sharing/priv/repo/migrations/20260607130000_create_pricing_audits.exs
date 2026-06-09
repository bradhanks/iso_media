defmodule PerfectPaper.Repo.Migrations.CreatePricingAudits do
  use Ecto.Migration

  # Brand-new table — safe in a normal (transactional) migration. The operator-
  # review indexes are created CONCURRENTLY in a separate migration.
  def change do
    create table(:pricing_audits, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Audit rows outlive a deleted user (nilify, never cascade-delete the record).
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      # Decision facts — written once, immutable.
      add :ip_country, :string
      add :payment_country, :string
      add :locale, :string
      add :applied_band, :string
      add :product, :string
      add :cadence, :string
      add :list_cents, :integer
      add :applied_cents, :integer
      # Multiplier in basis points (e.g. 7500 = 75%) to stay integer.
      add :applied_multiplier, :integer

      # Idempotency: a retried purchase (double-click / reconnect) hits this unique
      # key and the original decision is returned rather than a second row written.
      add :idempotency_key, :string

      # Risk columns — nullable + set-once (synchronously here, or once by the
      # deferred Oban enrichment via an `IS NULL`-guarded update).
      add :vpn?, :boolean
      add :datacenter?, :boolean
      add :risk_score, :integer

      # Point-in-time snapshots, not maintained lists.
      add :account_country_history, {:array, :string}, null: false, default: []
      add :mismatches, {:array, :string}, null: false, default: []

      # Decision facts are immutable: inserted_at only, no updated_at.
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:pricing_audits, [:idempotency_key])
    create index(:pricing_audits, [:user_id])
  end
end
