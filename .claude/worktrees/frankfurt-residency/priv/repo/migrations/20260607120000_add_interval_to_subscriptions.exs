defmodule PerfectPaper.Repo.Migrations.AddIntervalToSubscriptions do
  use Ecto.Migration

  def up do
    execute "SET lock_timeout = '5s'"

    alter table(:subscriptions) do
      add :interval, :string, null: false, default: "month"
    end
  end

  def down do
    alter table(:subscriptions) do
      remove :interval
    end
  end
end
