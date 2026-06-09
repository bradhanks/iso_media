defmodule PerfectPaper.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhook_endpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :url, :string, null: false
      add :secret, :string, null: false
      add :event_types, {:array, :string}, null: false, default: []
      add :description, :string
      add :active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create index(:webhook_endpoints, [:organization_id])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :endpoint_id, references(:webhook_endpoints, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :event_id, :binary_id
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :response_status, :integer
      add :last_error, :string
      add :delivered_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:webhook_deliveries, [:endpoint_id])
    create index(:webhook_deliveries, [:status])
  end
end
