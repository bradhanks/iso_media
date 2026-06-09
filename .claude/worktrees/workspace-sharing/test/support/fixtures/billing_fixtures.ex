defmodule PerfectPaper.BillingFixtures do
  @moduledoc "Test fixtures for the Billing context."

  alias PerfectPaper.Billing

  import PerfectPaper.AccountsFixtures, only: [user_fixture: 0]

  @doc """
  Creates a subscription for the given user at the given plan (default:
  `:professional`).

  Calls `Billing.upgrade_plan/2` so the stub provider IDs are populated.
  """
  def subscription_fixture(user \\ nil, plan \\ :professional) do
    user = user || user_fixture()
    {:ok, subscription} = Billing.upgrade_plan(user, plan)
    subscription
  end

  @doc "Creates a personal annual subscription for the user (billing_period: :annual)."
  def annual_subscription_for(user, plan \\ :professional) do
    {:ok, sub} = Billing.upgrade_plan(user, plan)
    Billing.set_billing_period(sub, :annual)
  end
end
