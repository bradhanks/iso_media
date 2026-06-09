defmodule PerfectPaper.Repo.Migrations.CreateScimTokens do
  use Ecto.Migration

  def change do
    create table(:scim_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :created_by, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:scim_tokens, [:organization_id])
    create unique_index(:scim_tokens, [:token_hash])
  end
end
