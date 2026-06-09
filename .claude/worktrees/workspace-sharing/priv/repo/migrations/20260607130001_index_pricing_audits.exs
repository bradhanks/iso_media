defmodule PerfectPaper.Repo.Migrations.IndexPricingAudits do
  use Ecto.Migration

  # Operator-review + retention indexes, built CONCURRENTLY so creating them never
  # holds a write lock on the append-only audit log (zero-downtime, std 4).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Retention sweep + chronological review scan by age.
    create index(:pricing_audits, [:inserted_at], concurrently: true)

    # "Show me flagged decisions" stays cheap without scanning the full log.
    create index(:pricing_audits, [:risk_score],
             where: "risk_score > 0",
             name: :pricing_audits_flagged_index,
             concurrently: true
           )
  end

  def down do
    drop index(:pricing_audits, [:inserted_at], concurrently: true)
    drop index(:pricing_audits, [:risk_score], name: :pricing_audits_flagged_index, concurrently: true)
  end
end
