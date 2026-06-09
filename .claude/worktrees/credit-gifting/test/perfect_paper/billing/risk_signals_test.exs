defmodule PerfectPaper.Billing.RiskSignalsTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Billing.RiskSignals

  defmodule FailingAdapter do
    @behaviour RiskSignals
    @impl true
    def check(_ip, _opts), do: {:error, :boom}
  end

  defmodule RaisingAdapter do
    @behaviour RiskSignals
    @impl true
    def check(_ip, _opts), do: raise("upstream down")
  end

  describe "check/2" do
    test "the default stub flags nothing" do
      assert {:ok, %{vpn?: false, datacenter?: false, source: :stub}} =
               RiskSignals.check("203.0.113.7")
    end

    test "a nil / blank IP short-circuits to :risk_unknown" do
      assert :risk_unknown = RiskSignals.check(nil)
      assert :risk_unknown = RiskSignals.check("")
    end

    test "an adapter error becomes :risk_unknown (flag-don't-block)" do
      assert :risk_unknown = RiskSignals.check("203.0.113.7", risk_signals: FailingAdapter)
    end

    test "an adapter that raises becomes :risk_unknown (never stalls checkout)" do
      assert :risk_unknown = RiskSignals.check("203.0.113.7", risk_signals: RaisingAdapter)
    end

    test "an injected adapter overrides the configured provider" do
      defmodule OkAdapter do
        @behaviour RiskSignals
        @impl true
        def check(_ip, _opts),
          do: {:ok, %{vpn?: true, datacenter?: true, asn: 64_500, source: :test}}
      end

      assert {:ok, %{vpn?: true, datacenter?: true, asn: 64_500}} =
               RiskSignals.check("203.0.113.7", risk_signals: OkAdapter)
    end
  end
end
