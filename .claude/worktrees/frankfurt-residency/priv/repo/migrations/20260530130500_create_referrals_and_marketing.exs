defmodule PerfectPaper.Repo.Migrations.CreateReferralsAndMarketing do
  use Ecto.Migration

  def change do
    create table(:referrals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :referrer_user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :referee_user_id, :binary_id
      add :referral_code, :string, null: false
      add :first_payment_at, :utc_datetime
      add :rewards_issued_at, :utc_datetime
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:referrals, [:referral_code])
    create index(:referrals, [:referrer_user_id])

    create table(:marketing_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :opt_in, :boolean, null: false, default: false
      add :product_updates, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:marketing_preferences, [:user_id])
  end
end
