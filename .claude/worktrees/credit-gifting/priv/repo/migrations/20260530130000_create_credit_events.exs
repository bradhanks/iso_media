defmodule PerfectPaper.Repo.Migrations.CreateCreditEvents do
  use Ecto.Migration

  def change do
    create table(:credit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :amount, :integer, null: false
      add :reason, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:credit_events, [:user_id])
  end
end
