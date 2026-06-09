defmodule PerfectPaper.Billing.RiskSignals.Stub do
  @moduledoc """
  Default `RiskSignals` adapter: a no-op/basic check that flags nothing.

  Weak by design — real VPN/datacenter coverage needs a paid provider behind the
  same behaviour. Returns instantly (no external call), so it never stalls
  checkout and never fails.
  """
  @behaviour PerfectPaper.Billing.RiskSignals

  @impl true
  def check(_ip, _opts) do
    {:ok, %{vpn?: false, datacenter?: false, asn: nil, source: :stub}}
  end
end
