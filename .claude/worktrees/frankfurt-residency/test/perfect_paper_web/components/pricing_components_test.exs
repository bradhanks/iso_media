defmodule PerfectPaperWeb.PricingComponentsTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PerfectPaper.Billing.Prices
  alias PerfectPaperWeb.PricingComponents

  defp starter, do: Enum.find(Prices.subscriptions(), &(&1.key == :starter))

  describe "plan_card/1 — Band A (no regional discount)" do
    setup do
      html = render_component(&PricingComponents.plan_card/1, plan: starter(), band: :a)
      {:ok, html: html}
    end

    test "renders the full monthly price with no regional strike", %{html: html} do
      assert html =~ ~s(data-test-id="monthly-price")
      assert html =~ "$40"
      refute html =~ ~s(data-test-id="monthly-list")
    end

    test "still renders an annual block with the two-months-free strike", %{html: html} do
      assert html =~ ~s(data-test-id="annual-list")
      assert html =~ ~s(data-test-id="annual-price")
      # 12 served, 10 charged: list $480 struck, price $400.
      assert html =~ "$480"
      assert html =~ "$400"
    end

    test "shows no regional note at Band A", %{html: html} do
      refute html =~ ~s(data-test-id="regional-note")
    end
  end

  describe "plan_card/1 — Band C (regional discount)" do
    setup do
      html = render_component(&PricingComponents.plan_card/1, plan: starter(), band: :c)
      {:ok, html: html}
    end

    test "strikes the monthly list and shows the discounted price", %{html: html} do
      assert html =~ ~s(data-test-id="monthly-list")
      # Band C = 50%: $40 list struck, $20 charged.
      assert html =~ "$40"
      assert html =~ "$20"
    end

    test "shows the regional-pricing note", %{html: html} do
      assert html =~ ~s(data-test-id="regional-note")
      assert html =~ "Regional pricing"
    end
  end

  describe "plan_card/1 — EU Omnibus suppression" do
    test "suppresses the regional monthly strike and note for EU visitors" do
      html =
        render_component(&PricingComponents.plan_card/1, plan: starter(), band: :c, eu?: true)

      # Omnibus: no synthetic regional strike, no regional note...
      refute html =~ ~s(data-test-id="monthly-list")
      refute html =~ ~s(data-test-id="regional-note")
      # ...but the genuine annual saving still strikes.
      assert html =~ ~s(data-test-id="annual-list")
    end
  end

  describe "pricing_table/1" do
    setup do
      html =
        render_component(&PricingComponents.pricing_table/1,
          plans: Prices.subscriptions(),
          band: :a
        )

      {:ok, html: html}
    end

    test "renders the data-cadence container defaulting to monthly", %{html: html} do
      assert html =~ ~s(id="pricing-grid")
      assert html =~ ~s(data-cadence="monthly")
    end

    test "renders both cadence-toggle buttons", %{html: html} do
      assert html =~ ~s(data-test-id="cadence-monthly")
      assert html =~ ~s(data-test-id="cadence-annual")
    end

    test "renders a card for every subscription plan", %{html: html} do
      for plan <- Prices.subscriptions() do
        assert html =~ ~s(data-test-id="plan-card-#{plan.key}")
      end
    end
  end
end
