defmodule PerfectPaper.Credits.Tier do
  @moduledoc """
  Pure configuration for plan entitlements.

  No schema, no Repo — stateless config consulted at runtime. Each plan maps to:

  - `monthly_reviews` — full-review credits granted per month (1 credit = 1 full
    review). The `:preview` entitlement (a user with no paid subscription) gets
    none; they receive *free previews* instead.
  - `level` — the agentic processing level a review runs at for that plan:
    `:full` for paid plans, `:preview` (a lighter pass) for free previews.

  `:preview` is the fallback for any unknown / absent plan.
  """

  @type plan :: :preview | :starter | :professional | :advanced
  @type level :: :preview | :full
  @type limits :: %{monthly_reviews: non_neg_integer(), level: level()}

  @tiers %{
    preview: %{monthly_reviews: 0, level: :preview},
    starter: %{monthly_reviews: 1, level: :full},
    professional: %{monthly_reviews: 3, level: :full},
    advanced: %{monthly_reviews: 10, level: :full}
  }

  @doc "Returns the full map of all tier entitlements, keyed by plan atom."
  @spec all() :: %{plan() => limits()}
  def all, do: @tiers

  @doc """
  Returns the entitlement for the given plan.

  Defaults to the `:preview` entitlement for any unknown or `nil` plan.
  """
  @spec for_plan(atom()) :: limits()
  def for_plan(plan), do: Map.get(@tiers, plan, @tiers[:preview])

  @doc "The agentic processing level a review runs at for the given plan."
  @spec level_for(atom()) :: level()
  def level_for(plan), do: for_plan(plan).level
end
