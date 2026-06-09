defmodule PerfectPaper.AccountsLocaleTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Accounts

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user_with_password(%{
        email: "loc-#{System.unique_integer([:positive])}@example.com",
        password: "supersecret-12chars"
      })

    user
  end

  test "new users default to English" do
    assert user_fixture().locale == "en"
  end

  test "update_user_locale persists a supported locale" do
    user = user_fixture()
    assert {:ok, updated} = Accounts.update_user_locale(user, "de")
    assert updated.locale == "de"
  end

  test "update_user_locale rejects an unsupported locale" do
    user = user_fixture()
    assert {:error, changeset} = Accounts.update_user_locale(user, "zz")
    assert "is invalid" in errors_on(changeset).locale
  end

  test "registration persists an explicit locale from attrs" do
    {:ok, user} =
      Accounts.register_user_with_password(%{
        email: "de-#{System.unique_integer([:positive])}@example.com",
        password: "supersecret-12chars",
        locale: "de"
      })

    assert user.locale == "de"
  end

  test "registration ignores an unsupported locale and keeps the default" do
    {:ok, user} =
      Accounts.register_user_with_password(%{
        email: "bad-#{System.unique_integer([:positive])}@example.com",
        password: "supersecret-12chars",
        locale: "zz"
      })

    assert user.locale == "en"
  end
end
