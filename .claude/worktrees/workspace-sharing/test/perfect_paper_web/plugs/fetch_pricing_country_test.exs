defmodule PerfectPaperWeb.Plugs.FetchPricingCountryTest do
  use PerfectPaperWeb.ConnCase, async: true

  alias PerfectPaperWeb.Plugs.FetchPricingCountry

  setup %{conn: conn} do
    # The plug writes :pricing_band to the session, so it needs a fetched session.
    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  defp run(conn), do: FetchPricingCountry.call(conn, FetchPricingCountry.init([]))

  test "maps CF-IPCountry to a band, stashing assigns + session", %{conn: conn} do
    conn = conn |> put_req_header("cf-ipcountry", "IN") |> run()

    assert conn.assigns.pricing_country == "IN"
    assert conn.assigns.pricing_band == :c
    assert get_session(conn, :pricing_band) == :c
    assert get_session(conn, :pricing_country) == "IN"
  end

  test "a high-income country → Band A (full price)", %{conn: conn} do
    conn = conn |> put_req_header("cf-ipcountry", "US") |> run()
    assert conn.assigns.pricing_band == :a
  end

  test "missing / empty / XX header → nil country, Band A (safe default)", %{conn: conn} do
    for header <- [nil, "", "XX"] do
      c = if header, do: put_req_header(conn, "cf-ipcountry", header), else: conn
      c = run(c)

      assert c.assigns.pricing_country == nil
      assert c.assigns.pricing_band == :a
      assert get_session(c, :pricing_band) == :a
    end
  end
end
