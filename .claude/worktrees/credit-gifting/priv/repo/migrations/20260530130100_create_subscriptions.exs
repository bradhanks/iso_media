defmodule PerfectPaper.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :plan, :string, null: false, default: "free"
      add :status, :string, null: false, default: "active"
      add :provider_customer_id, :string
      add :provider_subscription_id, :string
      add :current_period_end, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subscriptions, [:user_id])
  end
end
