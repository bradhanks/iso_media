defmodule PerfectPaperWeb.DesignSystemTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PerfectPaperWeb.DesignSystem

  test "logo/1 renders the requested lockup" do
    assert render_component(&logo/1, variant: "icon") =~ "/images/icon-mulberry.svg"
    assert render_component(&logo/1, %{}) =~ "/images/logo.svg"
    assert render_component(&logo/1, %{}) =~ ~s(alt="PerfectPaper")
  end

  test "loading/1 renders daisyUI loading classes" do
    html = render_component(&loading/1, kind: "dots", size: "sm")
    assert html =~ "loading"
    assert html =~ "loading-dots"
    assert html =~ "loading-sm"
  end

  test "tabs/1 marks the active tab" do
    html =
      render_component(&tabs/1,
        tabs: [%{label: "Overview"}, %{label: "Activity", active: true}]
      )

    assert html =~ "Overview"
    assert html =~ "Activity"
    assert html =~ "tab-active"
  end

  test "menu/1 renders items, direction, and active state" do
    html =
      render_component(&menu/1,
        items: [%{label: "Inbox", active: true}, %{label: "Sent"}],
        direction: "horizontal"
      )

    assert html =~ "menu-horizontal"
    assert html =~ "Inbox"
    assert html =~ "menu-active"
  end
end
