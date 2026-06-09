defmodule PerfectPaper.MarketingFixtures do
  @moduledoc "Test fixtures for the Marketing context."

  alias PerfectPaper.Marketing

  @doc "Sets opt-in for the given user (defaults to true). Returns the saved preference."
  def preference_fixture(user, opt_in \\ true) do
    {:ok, preference} = Marketing.set_opt_in(user, opt_in)
    preference
  end
end
