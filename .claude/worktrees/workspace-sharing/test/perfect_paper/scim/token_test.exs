defmodule PerfectPaper.Scim.TokenTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Scim
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    user = user_fixture()
    org = organization_fixture(user)
    %{org: org, user: user}
  end

  test "generate_scim_token returns plaintext once and stores only a hash", %{
    org: org,
    user: user
  } do
    {:ok, plaintext} = Scim.generate_scim_token(org, user)
    assert String.starts_with?(plaintext, "scim_")
    row = Scim.get_token_by_org(org.id)
    refute row.token_hash == plaintext
    assert row.token_hash == PerfectPaper.Scim.Token.hash(plaintext)
  end

  test "verify_token resolves the org for a valid token", %{org: org, user: user} do
    {:ok, plaintext} = Scim.generate_scim_token(org, user)
    assert {:ok, resolved_org_id} = Scim.verify_token(plaintext)
    assert resolved_org_id == org.id
  end

  test "verify_token rejects an unknown/garbage token" do
    assert {:error, :unauthorized} = Scim.verify_token("scim_nope")
    assert {:error, :unauthorized} = Scim.verify_token("")
  end

  test "rotate replaces the hash; the old token stops working", %{org: org, user: user} do
    {:ok, old} = Scim.generate_scim_token(org, user)
    {:ok, new} = Scim.rotate_scim_token(org, user)
    assert {:error, :unauthorized} = Scim.verify_token(old)
    assert {:ok, _} = Scim.verify_token(new)
  end

  test "revoke removes the token", %{org: org, user: user} do
    {:ok, plaintext} = Scim.generate_scim_token(org, user)
    :ok = Scim.revoke_scim_token(org)
    assert {:error, :unauthorized} = Scim.verify_token(plaintext)
  end
end
