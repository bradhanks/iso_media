defmodule PerfectPaper.ApiKeysTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.ApiKeys

  import PerfectPaper.AccountsFixtures

  test "generate/2 returns a raw token that verify/1 accepts" do
    user = user_fixture()
    assert {:ok, raw, key} = ApiKeys.generate(user, "ci")
    assert is_binary(raw)
    assert String.starts_with?(raw, "pp_")
    assert key.user_id == user.id
    assert {:ok, verified} = ApiKeys.verify(raw)
    assert verified.id == key.id
  end

  test "verify/1 rejects unknown and revoked keys" do
    user = user_fixture()
    {:ok, raw, key} = ApiKeys.generate(user, "ci")
    assert ApiKeys.verify("pp_nope") == {:error, :invalid}
    {:ok, _revoked} = ApiKeys.revoke_key(key)
    assert ApiKeys.verify(raw) == {:error, :invalid}
  end

  test "verify/1 stamps last_used_at on success" do
    user = user_fixture()
    {:ok, raw, key} = ApiKeys.generate(user, "ci")
    assert is_nil(key.last_used_at)

    assert {:ok, verified} = ApiKeys.verify(raw)
    assert verified.last_used_at != nil
  end

  test "list_keys/1 returns only the user's active keys" do
    user = user_fixture()
    {:ok, _raw, key} = ApiKeys.generate(user, "a")
    {:ok, _raw2, _key2} = ApiKeys.generate(user, "b")
    assert length(ApiKeys.list_keys(user.id)) == 2
    {:ok, _} = ApiKeys.revoke_key(key)
    assert length(ApiKeys.list_keys(user.id)) == 1
  end
end
