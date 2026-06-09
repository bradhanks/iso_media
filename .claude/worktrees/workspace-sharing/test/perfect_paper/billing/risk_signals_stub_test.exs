defmodule PerfectPaper.Billing.RiskSignalsStubTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Billing.RiskSignals.Stub

  test "stub returns a well-shaped, non-vendor map" do
    assert {:ok, %{vpn?: false, datacenter?: false, asn: nil, source: :stub}} =
             Stub.check("203.0.113.1", [])
  end

  test "Stub implements the RiskSignals behaviour" do
    assert PerfectPaper.Billing.RiskSignals in (Stub.module_info(:attributes)[:behaviour] || [])
  end
end
