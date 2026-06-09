defmodule PerfectPaperWeb.LocaleControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "sets the pp_locale cookie and redirects back", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "de", "return_to" => "/"})
    assert redirected_to(conn) == "/"
    assert %{value: "de"} = conn.resp_cookies["pp_locale"]
  end

  test "rejects an unknown locale (no cookie set) and still redirects", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "zz", "return_to" => "/"})
    assert redirected_to(conn) == "/"
    refute Map.has_key?(conn.resp_cookies, "pp_locale")
  end

  test "an off-site return_to is rejected in favor of home", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{"locale" => "de", "return_to" => "https://evil.example.com"})
    assert redirected_to(conn) == "/"
  end
end
