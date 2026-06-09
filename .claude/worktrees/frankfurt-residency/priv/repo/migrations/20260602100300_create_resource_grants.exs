defmodule PerfectPaper.Repo.Migrations.CreateResourceGrants do
  use Ecto.Migration

  def change do
    create table(:resource_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false
      add :subject_type, :string, null: false
      add :subject_id, :binary_id, null: false
      add :role, :string, null: false
      add :granted_by, :binary_id

      timestamps(type: :utc_datetime)
    end

    create unique_index(:resource_grants, [:resource_type, :resource_id, :subject_type, :subject_id],
             name: :resource_grants_unique_index
           )

    create index(:resource_grants, [:subject_type, :subject_id])
  end
end
