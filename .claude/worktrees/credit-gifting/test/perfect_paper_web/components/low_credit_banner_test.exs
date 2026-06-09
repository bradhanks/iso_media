defmodule PerfectPaperWeb.LowCreditBannerTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias PerfectPaperWeb.LowCreditBanner

  defp render_banner(assigns), do: render_component(&LowCreditBanner.banner/1, assigns)

  test "shows when balance <= threshold (> 0), with the 12-pack CTA at the Band-A price" do
    html =
      render_banner(%{
        alert: %{balance: 1, threshold: 1, annual?: false, band: :a},
        dismissed?: false
      })

    assert html =~ ~s(data-testid="low-credit-banner")
    assert html =~ "$498"
    assert html =~ "/billing"
  end

  test "hidden when balance is above threshold" do
    html =
      render_banner(%{
        alert: %{balance: 5, threshold: 1, annual?: false, band: :a},
        dismissed?: false
      })

    refute html =~ ~s(data-testid="low-credit-banner")
  end

  test "hidden when threshold is 0 (disabled) even at zero balance" do
    html =
      render_banner(%{
        alert: %{balance: 0, threshold: 0, annual?: false, band: :a},
        dismissed?: false
      })

    refute html =~ ~s(data-testid="low-credit-banner")
  end

  test "hidden when dismissed for the session" do
    html =
      render_banner(%{
        alert: %{balance: 1, threshold: 1, annual?: false, band: :a},
        dismissed?: true
      })

    refute html =~ ~s(data-testid="low-credit-banner")
  end

  test "annual subscriber sees the finish-your-year variant" do
    html =
      render_banner(%{
        alert: %{balance: 4, threshold: 5, annual?: true, band: :a},
        dismissed?: false
      })

    assert html =~ "year"
  end
end
