defmodule PerfectPaper.Billing.PricingAuditAnonymizerTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Billing
  alias PerfectPaper.Billing.{PricingAudit, PricingAuditAnonymizer}

  import PerfectPaper.AccountsFixtures

  defp record(user, key) do
    {:ok, audit} =
      Billing.record_pricing_decision(%{
        user_id: user.id,
        ip_country: "US",
        payment_country: "US",
        applied_band: :a,
        product: "starter",
        cadence: "monthly",
        list_cents: 4000,
        applied_cents: 4000,
        applied_multiplier: 10_000,
        idempotency_key: key,
        signals: :risk_unknown
      })

    audit
  end

  defp backdate(audit, days) do
    old = DateTime.add(DateTime.utc_now(), -days * 86_400, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(a in PricingAudit, where: a.id == ^audit.id), set: [inserted_at: old])
  end

  describe "anonymize_pricing_audits_before/2" do
    test "anonymizes aged rows, leaves recent rows, is idempotent + terminates" do
      user = user_fixture()
      old = record(user, "old")
      _recent = record(user, "recent")
      backdate(old, 200)

      cutoff = DateTime.add(DateTime.utc_now(), -180 * 86_400, :second)

      assert {:ok, 1} = Billing.anonymize_pricing_audits_before(cutoff, 100)

      # Re-running drains nothing (already-anonymized rows are excluded → loop ends).
      assert {:ok, 0} = Billing.anonymize_pricing_audits_before(cutoff, 100)

      anonymized = Repo.get!(PricingAudit, old.id)
      assert anonymized.user_id == nil
      assert anonymized.ip_country == nil
      # Aggregate facts survive.
      assert anonymized.applied_band == "a"
      assert anonymized.applied_cents == 4000

      recent_row = Repo.get_by!(PricingAudit, idempotency_key: "recent")
      assert recent_row.user_id == user.id
    end
  end

  describe "PricingAuditAnonymizer worker" do
    test "perform/1 sweeps rows older than the 180-day retention window" do
      user = user_fixture()
      old = record(user, "old")
      backdate(old, PricingAuditAnonymizer.retention_days() + 5)

      assert :ok = PricingAuditAnonymizer.perform(%Oban.Job{args: %{}})

      assert Repo.get!(PricingAudit, old.id).user_id == nil
    end
  end
end
