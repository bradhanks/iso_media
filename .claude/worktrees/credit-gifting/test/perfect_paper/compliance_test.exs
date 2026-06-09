defmodule PerfectPaper.ComplianceTest do
  # Pure functional core — no Repo, no DB.
  use ExUnit.Case, async: true

  alias PerfectPaper.Compliance
  alias PerfectPaper.Compliance.CookieConsent

  describe "default_consent/1 (pre-decision defaults by region)" do
    test "US visitors start with analytics and marketing granted (opt-out regime)" do
      consent = Compliance.default_consent("US")

      assert consent.essential
      assert consent.analytics
      assert consent.marketing
    end

    test "non-US visitors start with all non-essential cookies denied (opt-in regime)" do
      for country <- ["DE", "FR", "GB", "ES", "NL", "CA", "RO", "RU"] do
        consent = Compliance.default_consent(country)

        assert consent.essential, "essential must always be on for #{country}"
        refute consent.analytics, "analytics must default off for #{country}"
        refute consent.marketing, "marketing must default off for #{country}"
      end
    end

    test "unknown/missing region defaults to deny (the safe default)" do
      for country <- [nil, "", "XX", "T1"] do
        consent = Compliance.default_consent(country)
        assert consent.essential
        refute consent.analytics
        refute consent.marketing
      end
    end
  end

  describe "build_consent/2" do
    test "accept_all grants every category" do
      assert {:ok, consent} = Compliance.build_consent(:accept_all, region: "DE")
      assert consent.essential
      assert consent.analytics
      assert consent.marketing
      assert consent.version == Compliance.consent_version()
      assert consent.region == "DE"
      assert %DateTime{} = consent.decided_at
    end

    test "reject_all denies every non-essential category but keeps essential" do
      assert {:ok, consent} = Compliance.build_consent(:reject_all, region: "DE")
      assert consent.essential
      refute consent.analytics
      refute consent.marketing
      assert %DateTime{} = consent.decided_at
    end

    test "custom params honor each checkbox and force essential on" do
      assert {:ok, consent} =
               Compliance.build_consent(%{"analytics" => "true", "marketing" => "false"},
                 region: "FR"
               )

      assert consent.essential
      assert consent.analytics
      refute consent.marketing
    end

    test "an omitted checkbox is treated as denied" do
      assert {:ok, consent} = Compliance.build_consent(%{}, region: "FR")
      refute consent.analytics
      refute consent.marketing
    end
  end

  describe "cookie round-trip" do
    test "encode_cookie/1 then consent_from_cookie/2 preserves the decision" do
      {:ok, consent} = Compliance.build_consent(%{"analytics" => "true"}, region: "NL")

      decoded =
        consent
        |> Compliance.encode_cookie()
        |> Compliance.consent_from_cookie("NL")

      assert decoded.analytics
      refute decoded.marketing
      assert decoded.region == "NL"
      assert decoded.version == Compliance.consent_version()
    end

    test "consent_from_cookie/2 returns nil when the stored version is stale" do
      stale = %{
        "version" => Compliance.consent_version() - 1,
        "analytics" => true,
        "marketing" => true,
        "region" => "DE"
      }

      assert Compliance.consent_from_cookie(stale, "DE") == nil
    end

    test "consent_from_cookie/2 returns nil when no cookie is present" do
      assert Compliance.consent_from_cookie(nil, "DE") == nil
    end
  end

  describe "changeset" do
    test "always forces essential to true even if a caller tries to disable it" do
      changeset =
        CookieConsent.changeset(%CookieConsent{}, %{
          essential: false,
          analytics: false,
          marketing: false,
          version: Compliance.consent_version(),
          decided_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert Ecto.Changeset.get_field(changeset, :essential) == true
    end
  end

  describe "submit_dsar/1" do
    test "returns error changeset for missing required fields" do
      assert {:error, changeset} = Compliance.submit_dsar(%{})
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :email)
      assert Map.has_key?(errors, :request_type)
    end

    test "returns error changeset for invalid email" do
      assert {:error, changeset} =
               Compliance.submit_dsar(%{
                 name: "Alice",
                 email: "not-an-email",
                 request_type: :access
               })

      assert Map.has_key?(errors_on(changeset), :email)
    end

    test "succeeds with valid params (mailer stubbed in test env)" do
      assert {:ok, dsar} =
               Compliance.submit_dsar(%{
                 name: "Alice Researcher",
                 email: "alice@uni.edu",
                 request_type: :erasure,
                 message: "Please delete all my data."
               })

      assert dsar.name == "Alice Researcher"
      assert dsar.request_type == :erasure
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
