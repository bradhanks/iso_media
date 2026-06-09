defmodule PerfectPaper.Repo.Migrations.CreateTeamsLinks do
  use Ecto.Migration

  def change do
    create table(:teams_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :aad_object_id, :string, null: false
      add :tenant_id, :string, null: false
      add :service_url, :string
      add :conversation_reference, :map, null: false, default: %{}
      add :muted, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:teams_links, [:user_id])
    create unique_index(:teams_links, [:aad_object_id])
  end
end
