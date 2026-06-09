defmodule PerfectPaper.Repo.Migrations.AddPolymorphicOwnership do
  use Ecto.Migration

  def up do
    alter table(:history_sessions) do
      add :owner_type, :string
      add :owner_id, :binary_id
      add :organization_id, :binary_id
      add :owner_path, :text
    end

    alter table(:documents) do
      add :owner_type, :string
      add :owner_id, :binary_id
      add :organization_id, :binary_id
      add :owner_path, :text
    end

    # Backfill existing single-owner rows. Idempotent (guarded on NULL).
    execute """
    UPDATE history_sessions
    SET owner_type = 'user', owner_id = user_id
    WHERE owner_id IS NULL
    """

    execute """
    UPDATE documents
    SET owner_type = 'user', owner_id = user_id
    WHERE owner_id IS NULL
    """

    # Sessions are the fully-wired resource — enforce presence now.
    alter table(:history_sessions) do
      modify :owner_type, :string, null: false
      modify :owner_id, :binary_id, null: false
    end

    create index(:history_sessions, [:owner_type, :owner_id])
    create index(:history_sessions, [:organization_id])

    execute(
      "CREATE INDEX history_sessions_owner_path_gist_idx ON history_sessions USING GIST ((owner_path::ltree))",
      ""
    )
  end

  def down do
    execute "DROP INDEX IF EXISTS history_sessions_owner_path_gist_idx"
    drop index(:history_sessions, [:organization_id])
    drop index(:history_sessions, [:owner_type, :owner_id])

    alter table(:documents) do
      remove :owner_type
      remove :owner_id
      remove :organization_id
      remove :owner_path
    end

    alter table(:history_sessions) do
      remove :owner_type
      remove :owner_id
      remove :organization_id
      remove :owner_path
    end
  end
end
