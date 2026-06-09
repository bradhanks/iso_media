defmodule PerfectPaper.Repo.Migrations.CreateGroupMemberships do
  use Ecto.Migration

  def change do
    create table(:group_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "viewer"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_memberships, [:group_id, :user_id])
    create index(:group_memberships, [:user_id])
  end
end
