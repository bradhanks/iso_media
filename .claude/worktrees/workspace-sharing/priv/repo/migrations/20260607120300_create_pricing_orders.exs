defmodule PerfectPaper.Repo.Migrations.CreatePricingOrders do
  use Ecto.Migration

  def change do
    create table(:pricing_orders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :idempotency_key, :string, null: false
      add :product, :string, null: false
      add :cadence, :string, null: false
      add :applied_band, :string, null: false
      add :applied_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:pricing_orders, [:idempotency_key])
  end
end
