defmodule PerfectPaper.Audit.DeprovisioningTest do
  @moduledoc "Audit fixes: deprovisioning must revoke API keys + block API auth + drop org-admin authority."
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Accounts, ApiKeys, Organizations}
  alias PerfectPaperWeb.Tokens
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  describe "deactivate_user revokes credentials" do
    test "API keys are revoked and no longer verify after deactivation" do
      user = user_fixture()
      {:ok, raw, _key} = ApiKeys.generate(user, "ci")
      assert {:ok, _} = ApiKeys.verify(raw)

      {:ok, _} = Accounts.deactivate_user(user)

      assert {:error, :invalid} = ApiKeys.verify(raw)
      assert ApiKeys.list_keys(user.id) == []
    end

    test "a deactivated user's API-key bearer is rejected by the REST auth path" do
      user = user_fixture()
      {:ok, raw, _key} = ApiKeys.generate(user, "ci")
      assert {:ok, _} = Tokens.user_for_bearer(raw)

      {:ok, _} = Accounts.deactivate_user(user)

      assert {:error, :invalid} = Tokens.user_for_bearer(raw)
    end
  end

  describe "org-admin authority drops on deactivated membership" do
    test "admin? returns false once the admin membership is deactivated" do
      owner = user_fixture()
      admin = user_fixture()
      org = organization_fixture(owner)
      {:ok, _} = Organizations.add_member(org, admin, :admin)

      assert Organizations.admin?(org, admin.id)
      assert Organizations.admin?(org.id, admin.id)

      {:ok, _} = Organizations.deactivate_membership(org, admin.id)

      refute Organizations.admin?(org, admin.id)
      refute Organizations.admin?(org.id, admin.id)
      # admin_orgs no longer lists the org for the removed admin
      refute Enum.any?(Organizations.admin_orgs(admin.id), &(&1.id == org.id))
    end

    test "the canonical org owner stays admin regardless of membership status" do
      owner = user_fixture()
      org = organization_fixture(owner)
      assert Organizations.admin?(org, owner.id)
      assert Enum.any?(Organizations.admin_orgs(owner.id), &(&1.id == org.id))
    end
  end
end
