defmodule PerfectPaperWeb.Plugs.FetchLocaleTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "Accept-Language sets the locale assign + Gettext locale", %{conn: conn} do
    conn = conn |> put_req_header("accept-language", "de-DE,de;q=0.9") |> get(~p"/")
    assert conn.assigns.locale == "de"
  end

  test "the pp_locale cookie overrides Accept-Language for anonymous visitors", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept-language", "de")
      |> put_req_cookie("pp_locale", "nl")
      |> get(~p"/")

    assert conn.assigns.locale == "nl"
  end

  test "an unknown locale value falls back to the default", %{conn: conn} do
    conn = conn |> put_req_cookie("pp_locale", "zz") |> get(~p"/")
    assert conn.assigns.locale == "en"
  end
end
