defmodule PerfectPaper.Billing.ChargeResolutionTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Billing
  alias PerfectPaper.Billing.{Pricing, PricingAudit}

  import PerfectPaper.AccountsFixtures

  defmodule VpnAdapter do
    @behaviour PerfectPaper.Billing.RiskSignals
    @impl true
    def check(_ip, _opts),
      do: {:ok, %{vpn?: true, datacenter?: false, asn: 64_500, source: :test}}
  end

  describe "resolve_charge/7 — binding band" do
    test "a high-income visitor pays full price (Band A, no strike)" do
      user = user_fixture()

      assert {:ok, result} =
               Billing.resolve_charge(user, :starter, :monthly, "US", "US", nil)

      assert result.band == :a
      assert result.applied_cents == 4000
      assert result.list_cents == 4000
    end

    test "the LESS generous of IP/payment binds — spoofed IP yields no discount" do
      user = user_fixture()

      # IP in India (Band C) but payment in the US (Band A) → A binds.
      assert {:ok, result} =
               Billing.resolve_charge(user, :starter, :monthly, "IN", "US", nil)

      assert result.band == :a
      assert result.applied_cents == 4000
    end

    test "a genuine low-band payment country binds the discount" do
      user = user_fixture()

      assert {:ok, result} =
               Billing.resolve_charge(user, :starter, :monthly, "IN", "IN", nil)

      assert result.band == :c
      # Band C = 50% of $40.
      assert result.applied_cents == 2000
    end

    test "stub nil payment country → Band A binding (display discount not yet enforced)" do
      user = user_fixture()
      assert {:ok, result} = Billing.resolve_charge(user, :starter, :monthly, "IN", nil, nil)
      assert result.band == :a
      assert result.applied_cents == 4000
    end

    test "prices the annual cadence for a subscription" do
      user = user_fixture()
      assert {:ok, result} = Billing.resolve_charge(user, :starter, :annual, "US", "US", nil)
      # 10 charged / 12 served at $40.
      assert result.applied_cents == 40_000
    end

    test "prices a credit pack via the volume-aware pack pricer" do
      user = user_fixture()
      assert {:ok, result} = Billing.resolve_charge(user, :pack_12, :monthly, "US", "US", nil)

      expected =
        Pricing.pack_price_for(
          Enum.find(PerfectPaper.Billing.Prices.credit_packs(), &(&1.key == :pack_12)),
          :a
        )

      assert result.applied_cents == expected.price
      assert result.applied_cents < result.list_cents
    end
  end

  describe "resolve_charge/7 — audit + risk" do
    test "appends a pricing-decision audit row for the user" do
      user = user_fixture()
      assert {:ok, result} = Billing.resolve_charge(user, :starter, :monthly, "US", "US", nil)

      assert %PricingAudit{} = result.audit
      assert [row] = Billing.list_pricing_decisions(user_id: user.id)
      assert row.id == result.audit.id
      assert row.applied_band == "a"
    end

    test "an injected VPN adapter flags the decision" do
      user = user_fixture()

      assert {:ok, result} =
               Billing.resolve_charge(user, :starter, :monthly, "US", "US", nil,
                 ip: "203.0.113.7",
                 risk_signals: VpnAdapter
               )

      assert "vpn" in result.audit.mismatches
      assert result.audit.vpn? == true
    end

    test "is idempotent on the idempotency key" do
      user = user_fixture()
      args = [user, :starter, :monthly, "US", "US", "buy-xyz"]

      assert {:ok, first} = apply(Billing, :resolve_charge, args)
      assert {:ok, again} = apply(Billing, :resolve_charge, args)
      assert first.audit.id == again.audit.id
      assert Repo.aggregate(PricingAudit, :count) == 1
    end

    test "emits the risk_signals telemetry span" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "risk-span-#{inspect(ref)}",
        [:perfect_paper, :billing, :risk_signals, :stop],
        fn _e, measurements, meta, _ -> send(parent, {:span, ref, measurements, meta}) end,
        nil
      )

      user = user_fixture()
      Billing.resolve_charge(user, :starter, :monthly, "US", "US", nil)

      assert_received {:span, ^ref, %{duration: _}, %{result: :risk_unknown}}
      :telemetry.detach("risk-span-#{inspect(ref)}")
    end
  end

  describe "resolve_charge/7 — guards" do
    test "rejects a non-user (org/group) context" do
      assert {:error, :org_purchase_unsupported} =
               Billing.resolve_charge(%{id: "org-1"}, :starter, :monthly, "US", "US", nil)
    end

    test "rejects an unknown product" do
      user = user_fixture()

      assert {:error, :unknown_product} =
               Billing.resolve_charge(user, :nonsense, :monthly, "US", "US", nil)
    end
  end
end
