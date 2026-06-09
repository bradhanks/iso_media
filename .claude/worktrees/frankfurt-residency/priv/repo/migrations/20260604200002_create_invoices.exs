defmodule PerfectPaper.Repo.Migrations.CreateInvoices do
  use Ecto.Migration

  def change do
    create table(:invoices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :contract_id, references(:org_contracts, type: :binary_id, on_delete: :delete_all), null: false
      add :number, :string, null: false
      add :period_start, :date, null: false
      add :period_end, :date, null: false
      add :seats_billed, :integer, null: false
      add :seat_overage, :integer, null: false, default: 0
      add :amount_cents, :integer, null: false
      add :funded_credits, :integer, null: false, default: 0
      add :status, :string, null: false, default: "issued"
      add :issued_at, :utc_datetime, null: false
      add :due_at, :utc_datetime, null: false
      add :paid_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:invoices, [:number])
    create index(:invoices, [:organization_id])
    create index(:invoices, [:status])
  end
end
