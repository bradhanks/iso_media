defmodule PerfectPaperWeb.LocaleSwitcherTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "the marketing header renders the language switcher with native names", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)

    assert body =~ ~s(aria-label="Change language")
    assert body =~ "Deutsch"
    assert body =~ "Français"
    # Posts to the locale endpoint with the locale value as the submit button.
    assert body =~ ~s(action="/locale")
    assert body =~ ~s(name="locale" value="de")
  end
end
