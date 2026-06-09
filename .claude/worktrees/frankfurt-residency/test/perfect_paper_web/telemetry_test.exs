defmodule PerfectPaperWeb.TelemetryTest do
  use ExUnit.Case, async: true

  test "metrics include the low_balance_alert summary + counter" do
    events =
      PerfectPaperWeb.Telemetry.metrics()
      |> Enum.map(& &1.event_name)

    assert [:perfect_paper, :credits, :low_balance_alert] in events
  end
end
