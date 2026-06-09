defmodule PerfectPaper.Repo.Migrations.AddStatusToMemberships do
  use Ecto.Migration

  def change do
    alter table(:memberships) do
      add :status, :string, null: false, default: "active"
      add :deactivated_at, :utc_datetime
    end

    create index(:memberships, [:status])
  end
end
