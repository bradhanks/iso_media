defmodule PerfectPaper.Repo.Migrations.CreateMfa do
  use Ecto.Migration

  def change do
    create table(:user_mfa_factors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :secret, :binary
      add :label, :string
      add :confirmed_at, :utc_datetime
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_mfa_factors, [:user_id, :type, :label])
    create index(:user_mfa_factors, [:user_id])

    create table(:mfa_recovery_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :code_hash, :string, null: false
      add :used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:mfa_recovery_codes, [:user_id])

    alter table(:users) do
      add :mfa_enabled, :boolean, null: false, default: false
    end

    alter table(:organizations) do
      add :mfa_required, :boolean, null: false, default: false
    end
  end
end
