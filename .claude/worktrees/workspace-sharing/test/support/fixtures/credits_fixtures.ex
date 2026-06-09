defmodule PerfectPaper.CreditsFixtures do
  @moduledoc "Test fixtures for the Credits context."

  @doc "Grants credits to the given user, defaulting to 100."
  def grant_fixture(user, amount \\ 100) do
    {:ok, event} = PerfectPaper.Credits.grant(user.id, amount, "fixture_grant")
    event
  end
end
