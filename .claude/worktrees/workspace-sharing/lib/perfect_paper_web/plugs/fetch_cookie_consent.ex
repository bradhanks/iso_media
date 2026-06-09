defmodule PerfectPaperWeb.Plugs.FetchCookieConsent do
  @moduledoc """
  Resolves the visitor's cookie-consent state and assigns it for the layout.

  Reads the signed consent cookie and Cloudflare's `CF-IPCountry` header, then
  assigns:

    * `:cookie_consent` — the effective `CookieConsent` (the stored decision, or
      the region-aware default when none has been made yet)
    * `:cookie_consent_decided?` — whether the visitor has actually chosen
    * `:show_cookie_banner` — whether to render the consent banner (i.e. not yet
      decided)

  The decision itself is recorded by `PerfectPaperWeb.CookieConsentController`.
  """

  import Plug.Conn

  alias PerfectPaper.Compliance

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn, signed: [Compliance.cookie_name()])
    country = country(conn)

    decided = Compliance.consent_from_cookie(conn.cookies[Compliance.cookie_name()], country)
    consent = decided || Compliance.default_consent(country)

    conn
    |> assign(:cookie_consent, consent)
    |> assign(:cookie_consent_decided?, not is_nil(decided))
    |> assign(:show_cookie_banner, is_nil(decided))
  end

  defp country(conn), do: Compliance.country_from_conn(conn)
end
