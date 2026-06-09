defmodule PerfectPaper.Credits.CampaignTest do
  use ExUnit.Case, async: true

  import PerfectPaper.Credits.Campaign

  describe "composable builders (pure)" do
    test "grant_credit |> grant_when |> grant_filter composes a spec, no side effects" do
      campaign =
        grant_credit(:preview, 1, "referral_accepted", to: :referrer_id)
        |> grant_when(:referral_accepted)
        |> grant_when(fn ctx -> ctx.referrer_id != ctx.referee_id end)
        |> grant_filter(:once_per, key: &"k:#{&1.referee_id}")

      assert campaign.effect == {:grant, :preview, 1, "referral_accepted"}
      assert campaign.trigger == :referral_accepted
      assert campaign.target == :referrer_id
      assert length(campaign.guards) == 1
      assert [{:once_per, key: key_fun}] = campaign.filters
      assert key_fun.(%{referee_id: "abc"}) == "k:abc"
    end

    test "convert_credit builds a convert effect" do
      campaign = convert_credit(:preview, :paid, 1, "referral_purchase", to: :referrer_id)

      assert campaign.effect == {:convert, :preview, :paid, 1, "referral_purchase"}
      assert campaign.target == :referrer_id
    end
  end
end
