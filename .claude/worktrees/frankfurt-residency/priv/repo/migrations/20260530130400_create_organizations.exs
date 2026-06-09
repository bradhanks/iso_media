defmodule PerfectPaper.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :credit_pool, :integer, null: false, default: 0
      add :owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:organizations, [:owner_id])

    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      add :allocated_credits, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:organization_id, :user_id])
    create index(:memberships, [:organization_id])
  end
end
