defmodule PerfectPaper.Repo.Migrations.AddPromotedAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :promoted_at, :utc_datetime, null: true
    end
  end
end
