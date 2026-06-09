defmodule PerfectPaper.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :prefix, :string, null: false
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_keys, [:token_hash])
    create index(:api_keys, [:user_id])
  end
end
