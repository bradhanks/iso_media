defmodule PerfectPaper.Repo.Migrations.CreateAuthzDecisions do
  use Ecto.Migration

  def change do
    create table(:authz_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject_id, :binary_id
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :binary_id
      add :decision, :string, null: false
      add :reason, :string

      # Append-only audit row; created_at only (no updates).
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:authz_decisions, [:subject_id])
    create index(:authz_decisions, [:resource_type, :resource_id])
  end
end
