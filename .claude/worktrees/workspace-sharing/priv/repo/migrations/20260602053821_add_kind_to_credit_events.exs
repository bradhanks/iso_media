defmodule PerfectPaper.Repo.Migrations.AddKindToCreditEvents do
  use Ecto.Migration

  def change do
    alter table(:credit_events) do
      # Which bucket the credit belongs to: :paid (full-review credits) or
      # :preview (free-preview credits). Existing rows are paid credits.
      add :kind, :string, null: false, default: "paid"
    end

    create index(:credit_events, [:user_id, :kind])
  end
end
