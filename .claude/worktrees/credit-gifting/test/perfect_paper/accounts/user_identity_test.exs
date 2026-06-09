defmodule PerfectPaper.Accounts.UserIdentityTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Accounts.UserIdentity

  @valid %{
    user_id: Ecto.UUID.generate(),
    provider: "google",
    provider_uid: "1234567890",
    provider_email: "person@example.com"
  }

  test "valid attributes produce a valid changeset" do
    assert UserIdentity.changeset(%UserIdentity{}, @valid).valid?
  end

  test "requires user_id, provider, and provider_uid" do
    changeset = UserIdentity.changeset(%UserIdentity{}, %{})
    errors = errors_on(changeset)
    assert errors[:user_id]
    assert errors[:provider]
    assert errors[:provider_uid]
  end

  test "rejects an unknown provider" do
    changeset = UserIdentity.changeset(%UserIdentity{}, %{@valid | provider: "myspace"})
    assert errors_on(changeset)[:provider]
  end

  test "accepts a scim: prefixed provider" do
    cs =
      UserIdentity.changeset(%UserIdentity{}, %{
        user_id: Ecto.UUID.generate(),
        provider: "scim:#{Ecto.UUID.generate()}",
        provider_uid: "ext-1"
      })

    assert cs.valid?
  end
end
