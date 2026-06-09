defmodule PerfectPaper.Repo.Migrations.AddBillingPeriodToSubscriptions do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add :billing_period, :string, null: false, default: "monthly"
    end

    create constraint(:subscriptions, :billing_period_check,
             check: "billing_period IN ('monthly', 'annual')"
           )
  end
end
