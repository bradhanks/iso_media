defmodule PerfectPaper.Billing.PricingTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Billing.{Pricing, Prices}

  describe "bands/0 + country_band/1" do
    test "bands carry the canonical basis-point multipliers" do
      bps = Map.new(Pricing.bands(), &{&1.key, &1.bps})
      assert bps == %{a: 10_000, b: 7_500, c: 5_000, d: 3_500}
    end

    test "maps countries to bands; unknown/nil → Band A (least discount)" do
      assert Pricing.country_band("US") == :a
      assert Pricing.country_band("MX") == :b
      assert Pricing.country_band("IN") == :c
      assert Pricing.country_band("ET") == :d
      assert Pricing.country_band("ZZ") == :a
      assert Pricing.country_band(nil) == :a
      assert Pricing.country_band("  mx ") == :b
    end

    test "eu_country?/1 flags EU/EEA states (for the Omnibus strike guard)" do
      assert Pricing.eu_country?("FR")
      assert Pricing.eu_country?("DE")
      assert Pricing.eu_country?("NO")
      assert Pricing.eu_country?(" de ")
      refute Pricing.eu_country?("US")
      refute Pricing.eu_country?("IN")
      refute Pricing.eu_country?(nil)
    end
  end

  describe "resolve_band/2 (less-generous wins — anti-arbitrage)" do
    test "picks the band with the larger bps (less discount)" do
      # IP in India (C), payment in US (A) → A binds (no discount via spoofed IP).
      assert Pricing.resolve_band("IN", "US") == :a
      assert Pricing.resolve_band("US", "IN") == :a
      # Both India → C.
      assert Pricing.resolve_band("IN", "IN") == :c
      # Single country resolves against itself (nil payment → A).
      assert Pricing.resolve_band("IN", nil) == :a
      assert Pricing.resolve_band("MX", "IN") == :b
    end
  end

  describe "price_for/2 — the worked subscription table (Starter, M = $40)" do
    setup do
      %{starter: Enum.find(Prices.subscriptions(), &(&1.key == :starter))}
    end

    # | Band | monthly | annual | annual_list | struck? |
    # |  A   |  $40    | $400   |  $480       | false   |
    # |  B   |  $30    | $300   |  $360       | true    |
    # |  C   |  $20    | $200   |  $240       | true    |
    # |  D   |  $14    | $140   |  $168       | true    |
    test "Band A — full price, monthly unstruck", %{starter: s} do
      p = Pricing.price_for(s, :a)
      assert {p.monthly_price, p.annual_price, p.annual_list} == {4000, 40_000, 48_000}
      refute p.struck?
      assert p.monthly_list == 4000
    end

    test "Band B (−25%)", %{starter: s} do
      p = Pricing.price_for(s, :b)
      assert {p.monthly_price, p.annual_price, p.annual_list} == {3000, 30_000, 36_000}
      assert p.struck?
    end

    test "Band C (−50%)", %{starter: s} do
      p = Pricing.price_for(s, :c)
      assert {p.monthly_price, p.annual_price, p.annual_list} == {2000, 20_000, 24_000}
    end

    test "Band D (−65%)", %{starter: s} do
      p = Pricing.price_for(s, :d)
      assert {p.monthly_price, p.annual_price, p.annual_list} == {1400, 14_000, 16_800}
    end

    test "reads list_cents from Prices (no duplicated numbers)", %{starter: s} do
      assert s.list_cents == 4000
      assert Pricing.price_for(s, :a).monthly_list == s.list_cents
    end
  end

  describe "pack_price_for/2" do
    setup do
      packs = Map.new(Prices.credit_packs(), &{&1.key, &1})
      %{packs: packs}
    end

    test "an undiscounted pack shows list, no strike (Band A, v = 1.0)", %{packs: packs} do
      p = Pricing.pack_price_for(packs.pack_3, :a)
      assert p.price == 14_999
      assert p.list == 14_999
      refute p.struck?
      refute p.volume_discount?
    end

    test "the 12-pack gets the 17% volume discount and strikes (Band A)", %{packs: packs} do
      p = Pricing.pack_price_for(packs.pack_12, :a)
      assert p.volume_discount?
      assert p.struck?
      assert p.price < p.list
      # 59999 × 0.83 = 49799 → nearest dollar 49800; clamped ≤ list.
      assert p.price == 49_800
    end

    test "regional band discounts and strikes an otherwise-flat pack", %{packs: packs} do
      p = Pricing.pack_price_for(packs.pack_3, :b)
      assert p.struck?
      assert p.price == 11_200
    end

    test "the inline single credit prices through the same band math" do
      assert Pricing.unit_price_for(:a).price == 4999
      assert Pricing.unit_price_for(:c).price <= 4999
    end
  end

  describe "properties" do
    test "round_psych/1 is idempotent" do
      for x <- [0, 1, 49, 50, 99, 100, 14_999, 49_799, 59_999, 123_456] do
        assert Pricing.round_psych(Pricing.round_psych(x)) == Pricing.round_psych(x)
      end
    end

    test "a pack price is never above its list, in any band (clamp invariant)" do
      for pack <- [Prices.credit_single() | Prices.credit_packs()],
          band <- [:a, :b, :c, :d] do
        p = Pricing.pack_price_for(pack, band)
        assert p.price <= p.list, "#{pack.key}/#{band}: #{p.price} > #{p.list}"
      end
    end
  end

  describe "format_cents/1" do
    test "whole dollars omit cents; otherwise pad to two places" do
      assert Pricing.format_cents(4000) == "$40"
      assert Pricing.format_cents(4999) == "$49.99"
      assert Pricing.format_cents(49_800) == "$498"
      assert Pricing.format_cents(11_205) == "$112.05"
    end
  end
end
