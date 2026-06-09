defmodule PerfectPaper.ComplianceCountryTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Compliance

  defp conn_with(country) do
    %Plug.Conn{} |> Plug.Conn.put_req_header("cf-ipcountry", country)
  end

  test "country_from_conn reads CF-IPCountry, treating ''/XX/missing as nil" do
    assert Compliance.country_from_conn(conn_with("DE")) == "DE"
    assert Compliance.country_from_conn(conn_with("XX")) == nil
    assert Compliance.country_from_conn(conn_with("")) == nil
    assert Compliance.country_from_conn(%Plug.Conn{}) == nil
  end

  test "eea? identifies EU/EEA members" do
    assert Compliance.eea?("DE")
    assert Compliance.eea?("RO")
    refute Compliance.eea?("US")
    refute Compliance.eea?(nil)
  end
end
