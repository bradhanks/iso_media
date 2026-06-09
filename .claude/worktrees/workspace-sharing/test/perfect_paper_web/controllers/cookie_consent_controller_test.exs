defmodule PerfectPaperWeb.CookieConsentControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  alias PerfectPaper.Compliance

  describe "region-aware defaults (FetchCookieConsent plug, observed end-to-end)" do
    test "a non-US visitor with no prior decision sees the banner and gets deny defaults", %{
      conn: conn
    } do
      conn = conn |> put_req_header("cf-ipcountry", "DE") |> get(~p"/")

      assert conn.assigns.show_cookie_banner
      refute conn.assigns.cookie_consent.analytics
      refute conn.assigns.cookie_consent.marketing

      body = html_response(conn, 200)
      assert body =~ ~s(id="cookie-consent-banner")
      # Consent Mode v2 must default-deny before any tag could load.
      assert body =~ "'analytics_storage': 'denied'"
    end

    test "a US visitor with no prior decision still sees the banner but defaults to granted", %{
      conn: conn
    } do
      conn = conn |> put_req_header("cf-ipcountry", "US") |> get(~p"/")

      assert conn.assigns.show_cookie_banner
      assert conn.assigns.cookie_consent.analytics
      assert html_response(conn, 200) =~ ~s(id="cookie-consent-banner")
    end

    test "a missing CF-IPCountry header is treated as non-US (safe default)", %{conn: conn} do
      conn = get(conn, ~p"/")
      refute conn.assigns.cookie_consent.analytics
    end
  end

  describe "POST /cookie-consent" do
    test "accept_all records consent, hides the banner on the next request", %{conn: conn} do
      conn =
        conn
        |> put_req_header("cf-ipcountry", "DE")
        |> post(~p"/cookie-consent", %{"action" => "accept_all", "return_to" => "/"})

      assert redirected_to(conn) == "/"
      assert %{value: _signed} = conn.resp_cookies[Compliance.cookie_name()]

      # Recycling carries the response cookie into the next request.
      next = conn |> recycle() |> put_req_header("cf-ipcountry", "DE") |> get(~p"/")
      refute next.assigns.show_cookie_banner
      assert next.assigns.cookie_consent.analytics
      assert html_response(next, 200) =~ "'analytics_storage': 'granted'"
      refute html_response(next, 200) =~ ~s(id="cookie-consent-banner")
    end

    test "reject_all records a deny decision and still hides the banner afterward", %{conn: conn} do
      conn =
        conn
        |> put_req_header("cf-ipcountry", "DE")
        |> post(~p"/cookie-consent", %{"action" => "reject_all", "return_to" => "/"})

      next = conn |> recycle() |> put_req_header("cf-ipcountry", "DE") |> get(~p"/")
      refute next.assigns.show_cookie_banner
      refute next.assigns.cookie_consent.analytics
      assert html_response(next, 200) =~ "'analytics_storage': 'denied'"
    end

    test "save honors individual checkboxes", %{conn: conn} do
      conn =
        post(conn, ~p"/cookie-consent", %{
          "action" => "save",
          "consent" => %{"analytics" => "true"},
          "return_to" => "/"
        })

      next = conn |> recycle() |> get(~p"/")
      assert next.assigns.cookie_consent.analytics
      refute next.assigns.cookie_consent.marketing
    end

    test "an off-site return_to is rejected in favor of the home page (open-redirect guard)", %{
      conn: conn
    } do
      conn =
        post(conn, ~p"/cookie-consent", %{
          "action" => "accept_all",
          "return_to" => "https://evil.example.com/phish"
        })

      assert redirected_to(conn) == "/"
    end
  end

  describe "GET /cookie-settings" do
    test "renders a standalone preference form so consent can be changed any time", %{conn: conn} do
      body = conn |> get(~p"/cookie-settings") |> html_response(200)

      assert body =~ "Cookie settings"
      assert body =~ ~s(name="consent[analytics]")
      assert body =~ ~s(name="consent[marketing]")
      # Essential is shown but cannot be turned off.
      assert body =~ "disabled"
    end
  end

  test "the footer links to the cookie settings page", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ ~s(href="/cookie-settings")
  end
end
