defmodule PerfectPaper.Credits.Campaigns do
  @moduledoc """
  The active credit-grant campaigns, expressed as data.

  This is the one place to tune the program: amounts, triggers, and policies all
  live here. We currently lean **generous** — the goal is network effects, not
  margin — and it's reignable by editing these definitions, with no change to the
  granting mechanics.

  Each campaign is a `PerfectPaper.Credits.Campaign` spec; `PerfectPaper.Credits`
  runs the ones whose `trigger` matches an incoming domain event.
  """
  import PerfectPaper.Credits.Campaign

  alias PerfectPaper.Accounts
  alias PerfectPaper.Credits.Campaign

  @doc "All active campaigns."
  @spec all() :: [Campaign.t()]
  def all,
    do: [signup_preview(), referral_signup(), referral_accepted(), referral_purchase()]

  @doc "Campaigns whose trigger matches the given domain event."
  @spec for_trigger(atom()) :: [Campaign.t()]
  def for_trigger(trigger), do: Enum.filter(all(), &(&1.trigger == trigger))

  @doc """
  New writers from an academic/government email get a free preview credit so they
  can try PerfectPaper once. Non-academic sign-ups don't get the free credit
  here — they earn it instead by arriving through a referral (see
  `referral_signup/0`), keeping the free tier for the academic audience.
  """
  def signup_preview do
    grant_credit(:preview, 1, "signup_bonus", to: :user_id)
    |> grant_when(:signup)
    |> grant_when(fn ctx -> Accounts.academic_email?(ctx[:email]) end)
    |> grant_filter(:once_per, key: &"signup_bonus:#{&1.user_id}")
  end

  @doc """
  A referred writer gets a free preview credit when they join — the referral-link
  path to the free tier, open to any email domain (the academic gate on
  `signup_preview/0` does not apply to invited writers).
  """
  def referral_signup do
    grant_credit(:preview, 1, "referral_signup", to: :referee_id)
    |> grant_when(:referral_accepted)
    |> grant_when(fn ctx -> ctx[:referrer_id] != ctx[:referee_id] end)
    |> grant_filter(:once_per, key: &"referral_signup:#{&1.referee_id}")
  end

  @doc "Referring someone who joins earns the referrer a free preview credit."
  def referral_accepted do
    grant_credit(:preview, 1, "referral_accepted", to: :referrer_id)
    |> grant_when(:referral_accepted)
    |> grant_when(fn ctx -> ctx[:referrer_id] != ctx[:referee_id] end)
    |> grant_filter(:once_per, key: &"referral_accepted:#{&1.referee_id}")
  end

  @doc "When a referred writer buys reviews, the referrer's preview credit upgrades to paid."
  def referral_purchase do
    convert_credit(:preview, :paid, 1, "referral_purchase", to: :referrer_id)
    |> grant_when(:referral_purchase)
    |> grant_filter(:once_per, key: &"referral_purchase:#{&1.referee_id}")
  end
end
