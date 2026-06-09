defmodule PerfectPaper.Repo.Migrations.AddCreditAlertThresholdToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :credit_alert_threshold, :integer, null: true
    end
  end
end
