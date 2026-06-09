defmodule PerfectPaperWeb.MarketingI18nTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "the home page renders German for a de visitor", %{conn: conn} do
    body = conn |> put_req_header("accept-language", "de") |> get(~p"/") |> html_response(200)
    # Nav "Pricing" and footer "Privacy policy" must appear in German
    assert body =~ "Preise"
    assert body =~ "Datenschutzrichtlinie"
  end

  test "the home page still renders English by default", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "Pricing"
  end
end
