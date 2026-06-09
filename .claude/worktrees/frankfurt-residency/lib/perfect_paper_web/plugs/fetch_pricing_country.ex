defmodule PerfectPaperWeb.Plugs.FetchPricingCountry do
  @moduledoc """
  Resolves the visitor's display country (Cloudflare `CF-IPCountry`) into a
  regional pricing **band** and stashes both in assigns AND the session.

  The session write is the single deterministic mechanism for the LiveView side:
  `mount/3` runs twice and the *connected* WebSocket mount has no conn assigns, so
  `billing_live` reads `:pricing_band` from the session (with `:x_headers`
  `cf-ipcountry` as a fallback only when the session is empty) — it never relies
  on a transient conn assign surviving the reconnect.

  The CF-IPCountry signal is **spoofable** and used for *display* only; the binding
  charge resolves against the payment-method country at checkout
  (`Billing.Pricing.resolve_band/2`).
  """
  import Plug.Conn

  alias PerfectPaper.Billing.Pricing
  alias PerfectPaper.Compliance

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    country = Compliance.country_from_conn(conn)
    band = Pricing.country_band(country)

    conn
    |> assign(:pricing_country, country)
    |> assign(:pricing_band, band)
    |> put_session(:pricing_band, band)
    |> put_session(:pricing_country, country)
  end
end
