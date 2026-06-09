defmodule PerfectPaperWeb.PageHTMLTest do
  use ExUnit.Case, async: true

  alias PerfectPaperWeb.PageHTML

  describe "pricing card helpers tolerate either Billing.Prices shape" do
    test "plan_name/1 reads the rich plan_map :name" do
      assert PageHTML.plan_name(%{name: "Starter", price_label: "$40"}) == "Starter"
    end

    test "plan_name/1 falls back to a humanized legacy :plan atom" do
      assert PageHTML.plan_name(%{plan: :free, price_cents: 0, interval: :month}) == "Free"

      assert PageHTML.plan_name(%{plan: :standard, price_cents: 1900, interval: :month}) ==
               "Standard"
    end

    test "plan_price/1 reads the rich plan_map :price_label" do
      assert PageHTML.plan_price(%{name: "Starter", price_label: "$40"}) == "$40"
    end

    test "plan_price/1 formats a legacy product map via Billing.Prices.price_label/1" do
      assert PageHTML.plan_price(%{plan: :free, price_cents: 0, interval: :month}) == "Free"

      assert PageHTML.plan_price(%{plan: :standard, price_cents: 1900, interval: :month}) ==
               "$19/mo"
    end
  end
end
