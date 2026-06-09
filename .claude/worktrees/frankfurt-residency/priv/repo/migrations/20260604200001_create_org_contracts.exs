defmodule PerfectPaper.Repo.Migrations.CreateOrgContracts do
  use Ecto.Migration

  def change do
    create table(:org_contracts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :seats, :integer, null: false
      add :price_per_seat_cents, :integer, null: false, default: 0
      add :per_seat_credits, :integer, null: false, default: 0
      add :interval, :string, null: false, default: "monthly"
      add :status, :string, null: false, default: "draft"
      add :term_start, :date
      add :term_end, :date
      add :po_number, :string
      add :net_terms_days, :integer, null: false, default: 30
      add :peak_seats_used, :integer, null: false, default: 0
      add :last_funded_period, :date
      add :created_by, references(:users, type: :binary_id, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:org_contracts, [:organization_id])
    # At most one ACTIVE contract per org (draft/expired/canceled unbounded).
    create unique_index(:org_contracts, [:organization_id],
             where: "status = 'active'",
             name: :unique_active_contract_per_org
           )
  end
end
