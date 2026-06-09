defmodule PerfectPaper.ReferralsFixtures do
  @moduledoc "Test fixtures for the Referrals context."

  alias PerfectPaper.Referrals

  @doc "Registers a referral for the given user. Accepts optional keyword overrides."
  def referral_fixture(user, opts \\ []) do
    {:ok, referral} = Referrals.register(user, opts)
    referral
  end
end
