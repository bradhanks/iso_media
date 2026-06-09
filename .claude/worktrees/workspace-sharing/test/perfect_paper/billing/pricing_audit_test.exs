defmodule PerfectPaper.Billing.PricingAuditTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Billing
  alias PerfectPaper.Billing.PricingAudit

  import PerfectPaper.AccountsFixtures

  defp decision(overrides) do
    Map.merge(
      %{
        user_id: nil,
        ip_country: "US",
        payment_country: "US",
        locale: "en",
        applied_band: :a,
        product: "starter",
        cadence: "monthly",
        list_cents: 4000,
        applied_cents: 4000,
        applied_multiplier: 10_000,
        idempotency_key: nil,
        signals: {:ok, %{vpn?: false, datacenter?: false}}
      },
      Map.new(overrides)
    )
  end

  describe "record_pricing_decision/1" do
    test "appends an unflagged Band-A decision with risk_score 0" do
      assert {:ok, %PricingAudit{} = audit} = Billing.record_pricing_decision(decision(%{}))

      assert audit.applied_band == "a"
      assert audit.product == "starter"
      assert audit.applied_cents == 4000
      assert audit.mismatches == []
      assert audit.risk_score == 0
      assert audit.account_country_history == []
    end

    test "flags an IP↔payment band mismatch" do
      assert {:ok, audit} =
               Billing.record_pricing_decision(
                 decision(%{ip_country: "IN", payment_country: "US", applied_band: :c})
               )

      assert "band_mismatch" in audit.mismatches
      assert audit.risk_score >= 1
    end

    test "flags a VPN signal" do
      assert {:ok, audit} =
               Billing.record_pricing_decision(
                 decision(%{signals: {:ok, %{vpn?: true, datacenter?: false}}})
               )

      assert "vpn" in audit.mismatches
      assert audit.vpn? == true
    end

    test "treats :risk_unknown as no VPN/datacenter flags" do
      assert {:ok, audit} = Billing.record_pricing_decision(decision(%{signals: :risk_unknown}))
      assert audit.vpn? == false
      assert audit.datacenter? == false
    end

    test "flags a country switch against the account's prior decisions" do
      user = user_fixture()
      {:ok, _} = Billing.record_pricing_decision(decision(%{user_id: user.id, ip_country: "US"}))

      assert {:ok, second} =
               Billing.record_pricing_decision(decision(%{user_id: user.id, ip_country: "IN"}))

      assert "US" in second.account_country_history
      assert "country_switch" in second.mismatches
    end

    test "is idempotent on idempotency_key — a retry returns the original row" do
      d = decision(%{idempotency_key: "buy-123"})
      assert {:ok, first} = Billing.record_pricing_decision(d)
      assert {:ok, again} = Billing.record_pricing_decision(d)

      assert again.id == first.id
      assert Repo.aggregate(PricingAudit, :count) == 1
    end

    test "emits the pricing_decision telemetry event" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "pricing-decision-#{inspect(ref)}",
        [:perfect_paper, :billing, :pricing_decision],
        fn _event, measurements, metadata, _ ->
          send(parent, {:telemetry, ref, measurements, metadata})
        end,
        nil
      )

      Billing.record_pricing_decision(decision(%{applied_cents: 2000, applied_multiplier: 5000}))

      assert_received {:telemetry, ^ref, %{applied_cents: 2000, list_cents: 4000},
                       %{applied_band: "a", product: "starter", mismatch?: false, risk_score: 0}}

      :telemetry.detach("pricing-decision-#{inspect(ref)}")
    end
  end

  describe "list_pricing_decisions/1" do
    test "filters by user and by flagged" do
      user = user_fixture()
      other = user_fixture()

      {:ok, _} = Billing.record_pricing_decision(decision(%{user_id: user.id}))

      {:ok, _flagged} =
        Billing.record_pricing_decision(
          decision(%{user_id: user.id, signals: {:ok, %{vpn?: true, datacenter?: false}}})
        )

      {:ok, _} = Billing.record_pricing_decision(decision(%{user_id: other.id}))

      assert length(Billing.list_pricing_decisions(user_id: user.id)) == 2
      assert length(Billing.list_pricing_decisions(user_id: other.id)) == 1

      flagged = Billing.list_pricing_decisions(user_id: user.id, flagged: true)
      assert length(flagged) == 1
      assert hd(flagged).risk_score >= 1
    end
  end

  describe "anonymize_pricing_audit/1" do
    test "nulls identifying + movement fields, keeps band/amount, is idempotent" do
      user = user_fixture()

      {:ok, _} =
        Billing.record_pricing_decision(
          decision(%{user_id: user.id, ip_country: "US", payment_country: "US"})
        )

      assert {:ok, 1} = Billing.anonymize_pricing_audit(user.id)

      # The row survives but is de-identified; aggregate facts remain.
      [row] =
        Billing.list_pricing_decisions(flagged: false) |> Enum.filter(&(&1.applied_band == "a"))

      assert row.user_id == nil
      assert row.ip_country == nil
      assert row.account_country_history == []
      assert row.applied_band == "a"
      assert row.applied_cents == 4000

      # Idempotent: nothing left for this user to anonymize.
      assert {:ok, 0} = Billing.anonymize_pricing_audit(user.id)
    end
  end
end
