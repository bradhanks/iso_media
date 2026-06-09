defmodule PerfectPaperWeb.I18nSmokeTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "the cookie banner renders in German for a de visitor", %{conn: conn} do
    body =
      conn
      |> put_req_header("cf-ipcountry", "DE")
      |> put_req_header("accept-language", "de")
      |> get(~p"/")
      |> html_response(200)

    assert body =~ "Ihre Datenschutzeinstellungen"
  end

  test "the same string renders in English by default", %{conn: conn} do
    body = conn |> put_req_header("cf-ipcountry", "DE") |> get(~p"/") |> html_response(200)
    assert body =~ "Your privacy choices"
  end
end
