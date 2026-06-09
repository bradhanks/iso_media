defmodule PerfectPaperWeb.PricingCardTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias PerfectPaperWeb.PricingCard

  defp render_card(assigns) do
    render_component(&PricingCard.plan_card/1, assigns)
  end

  test "Band A monthly shows price, no strike" do
    html = render_card(%{plan: :starter, band: :a, eea?: false, name: "Starter"})
    # Band A monthly: price == list ($40), so no struck span in monthly div
    assert html =~ "$40"
    refute html =~ "line-through\">$40"
  end

  test "Band C monthly is struck $40 -> $20" do
    html = render_card(%{plan: :starter, band: :c, eea?: false, name: "Starter"})
    assert html =~ "$40"
    assert html =~ "$20"
    assert html =~ "line-through"
  end

  test "EU visitor: regional strike suppressed, annual div still present" do
    html = render_card(%{plan: :starter, band: :c, eea?: true, name: "Starter"})
    refute html =~ ~s(line-through">$40)
    assert html =~ ~s(data-cadence="annual")
  end

  test "renders both cadence divs + JS toggle hooks" do
    card_html = render_card(%{plan: :starter, band: :a, eea?: false, name: "Starter"})
    toggle_html = render_component(&PricingCard.cadence_toggle/1, %{})

    assert card_html =~ ~s(data-cadence="monthly")
    assert card_html =~ ~s(data-cadence="annual")
    assert toggle_html =~ "phx-click"
  end
end
