defmodule PerfectPaper.AccountsOidcTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Accounts
  import PerfectPaper.AccountsFixtures

  test "get_oidc_identity_by_oid resolves user + org from an oidc identity" do
    user = user_fixture()
    org_id = Ecto.UUID.generate()

    {:ok, _} =
      Accounts.create_identity(user, %{
        provider: "oidc:#{org_id}",
        provider_uid: "aad-oid-9",
        provider_email: user.email
      })

    assert %{user: found, org_id: ^org_id} = Accounts.get_oidc_identity_by_oid("aad-oid-9")
    assert found.id == user.id
  end

  test "returns nil for an unknown oid" do
    assert is_nil(Accounts.get_oidc_identity_by_oid("nope"))
  end
end
