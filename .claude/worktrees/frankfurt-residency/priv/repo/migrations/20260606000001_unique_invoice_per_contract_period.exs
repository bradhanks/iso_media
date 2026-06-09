defmodule PerfectPaper.Repo.Migrations.UniqueInvoicePerContractPeriod do
  use Ecto.Migration

  # Enforce one invoice per (contract, billing period) at the DB level so
  # re-issuing the same period cannot double-fund the org credit pool. The
  # `last_funded_period` marker was written but never enforced anything.
  def change do
    create unique_index(:invoices, [:contract_id, :period_start],
             name: :invoices_contract_id_period_start_index
           )
  end
end
