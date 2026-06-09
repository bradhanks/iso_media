defmodule PerfectPaper.Repo.Migrations.AddAppliedPricingToSubscriptions do
  use Ecto.Migration

  # What the regional pricer actually resolved at purchase, persisted on the
  # subscription so a renewal / receipt can re-derive the same number without
  # re-running display-time signals. Nullable — pre-Phase-2 rows have none.
  def change do
    alter table(:subscriptions) do
      add :applied_band, :string
      add :applied_cents, :integer
    end
  end
end
