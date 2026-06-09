defmodule PerfectPaper.AccountsDirectoryTest do
  use PerfectPaper.DataCase, async: true
  import Ecto.Query
  alias PerfectPaper.Accounts
  alias PerfectPaper.Accounts.UserToken
  import PerfectPaper.AccountsFixtures

  test "deactivate_user stamps deactivated_at and deletes all tokens" do
    user = user_fixture()
    _ = Accounts.generate_user_session_token(user)
    assert {:ok, deactivated} = Accounts.deactivate_user(user)
    assert deactivated.deactivated_at
    assert Repo.aggregate(from(t in UserToken, where: t.user_id == ^user.id), :count) == 0
  end

  test "reactivate_user clears the flag" do
    user = user_fixture()
    {:ok, d} = Accounts.deactivate_user(user)
    assert {:ok, r} = Accounts.reactivate_user(d)
    refute r.deactivated_at
  end

  test "create_identity links a scim identity; get_user_by_identity finds it" do
    user = user_fixture()
    provider = "scim:#{Ecto.UUID.generate()}"

    assert {:ok, _} =
             Accounts.create_identity(user, %{
               provider: provider,
               provider_uid: "ext-9",
               provider_email: user.email
             })

    assert %{id: id} = Accounts.get_user_by_identity(provider, "ext-9")
    assert id == user.id
  end

  test "get_user_by_identity returns nil for an unknown identity" do
    assert is_nil(Accounts.get_user_by_identity("scim:#{Ecto.UUID.generate()}", "nope"))
  end

  test "find_or_provision_member creates a confirmed passwordless user, idempotently" do
    assert {:ok, user} = Accounts.find_or_provision_member("new@acme.com")
    assert user.confirmed_at
    assert is_nil(user.hashed_password)
    assert {:ok, same} = Accounts.find_or_provision_member("new@acme.com")
    assert same.id == user.id
  end

  test "existing_user_ids filters out non-existent ids" do
    user = user_fixture()
    ghost = Ecto.UUID.generate()
    assert Accounts.existing_user_ids([user.id, ghost]) == [user.id]
  end
end
