defmodule PerfectPaper.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :is_personal, :boolean, null: false, default: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create index(:workspaces, [:user_id])

    # At most one Personal workspace per user.
    create unique_index(:workspaces, [:user_id],
             where: "is_personal",
             name: :workspaces_one_personal_per_user
           )

    alter table(:history_sessions) do
      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :restrict)
    end

    create index(:history_sessions, [:workspace_id])

    alter table(:users) do
      add :active_workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
