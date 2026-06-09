defmodule PerfectPaper.Billing.PricesTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Billing.Prices

  test "credit_packs/0 returns the three bundles with integer list_cents" do
    packs = Prices.credit_packs()
    assert Enum.map(packs, & &1.key) == [:pack_3, :pack_6, :pack_12]
    assert Enum.count(packs, & &1.popular?) == 1
    assert Enum.all?(packs, &(&1.mode == :payment))
    # Single numeric source of truth — every product carries integer list_cents.
    assert Map.new(packs, &{&1.key, &1.list_cents}) == %{
             pack_3: 14_999,
             pack_6: 29_999,
             pack_12: 59_999
           }

    assert Enum.find(packs, &(&1.key == :pack_3)).price_label == "$149.99"
    # Only the largest bundle has a volume discount.
    assert Enum.find(packs, &(&1.key == :pack_12)).volume_bps == 8_300
    assert Enum.find(packs, &(&1.key == :pack_3)).volume_bps == 10_000
  end

  test "credit_single/0 is a separate inline product (not in the bundle list)" do
    refute Enum.any?(Prices.credit_packs(), &(&1.key == :credit_single))
    single = Prices.credit_single()
    assert single.key == :credit_single
    assert single.list_cents == 4999
    assert single.volume_bps == 10_000
  end

  test "subscriptions/0 carry integer list_cents for the band math" do
    subs = Prices.subscriptions()

    assert Map.new(subs, &{&1.key, &1.list_cents}) == %{
             starter: 4000,
             professional: 10_000,
             advanced: 30_000
           }
  end

  test "subscriptions/0 returns three monthly plans, exactly one popular" do
    subs = Prices.subscriptions()
    assert length(subs) == 3
    assert Enum.count(subs, & &1.popular?) == 1
    assert Enum.all?(subs, &(&1.mode == :subscription))
    assert Enum.find(subs, &(&1.key == :professional)).badge == "= $33.33 / review"
  end

  test "no plan copy mentions the legacy brand name" do
    blob = (Prices.credit_packs() ++ Prices.subscriptions()) |> inspect()
    refute blob =~ "Refine"
  end
end
