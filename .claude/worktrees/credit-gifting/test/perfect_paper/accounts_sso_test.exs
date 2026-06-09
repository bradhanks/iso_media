defmodule PerfectPaper.AccountsSsoTest do
  # async: false — `configured_providers/0` reads global application env, which
  # this test mutates; running sync avoids cross-test contamination.
  use PerfectPaper.DataCase, async: false

  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Accounts
  alias PerfectPaper.Accounts.{User, UserIdentity}
  alias PerfectPaper.Accounts.OAuth.Stub
  alias PerfectPaper.Repo

  defp identity(attrs) do
    Map.merge(
      %{provider: "google", uid: "uid-1", email: nil, email_verified: false, name: "A"},
      Map.new(attrs)
    )
  end

  describe "sso_sign_in/3" do
    test "known identity logs the existing user in" do
      user = user_fixture()

      {:ok, _} =
        Repo.insert(
          UserIdentity.changeset(%UserIdentity{}, %{
            user_id: user.id,
            provider: "google",
            provider_uid: "uid-1"
          })
        )

      Stub.put_identity(identity(uid: "uid-1", email: "whatever@example.com"))
      assert {:ok, %User{id: id}} = Accounts.sso_sign_in("google", %{}, %{})
      assert id == user.id
    end

    test "verified email matching an existing user auto-links" do
      user = user_fixture()
      Stub.put_identity(identity(email: user.email, email_verified: true))

      assert {:ok, %User{id: id}} = Accounts.sso_sign_in("google", %{}, %{})
      assert id == user.id

      assert Repo.get_by(UserIdentity, provider: "google", provider_uid: "uid-1").user_id ==
               user.id
    end

    test "new verified email creates a confirmed user and an identity" do
      email = unique_user_email()
      Stub.put_identity(identity(email: email, email_verified: true))

      assert {:ok, %User{} = user} = Accounts.sso_sign_in("google", %{}, %{})
      assert user.email == email
      assert user.confirmed_at

      assert Repo.get_by(UserIdentity, provider: "google", provider_uid: "uid-1").user_id ==
               user.id
    end

    test "new but unverified email creates an UNconfirmed user" do
      email = unique_user_email()
      Stub.put_identity(identity(email: email, email_verified: false))

      assert {:ok, %User{} = user} = Accounts.sso_sign_in("google", %{}, %{})
      assert user.email == email
      refute user.confirmed_at

      assert Repo.get_by(UserIdentity, provider: "google", provider_uid: "uid-1").user_id ==
               user.id
    end

    test "unverified email colliding with an existing user is rejected" do
      user = user_fixture()
      Stub.put_identity(identity(email: user.email, email_verified: false))

      assert {:error, :email_taken} = Accounts.sso_sign_in("google", %{}, %{})
      refute Repo.get_by(UserIdentity, provider: "google", provider_uid: "uid-1")
    end

    test "missing email is rejected" do
      Stub.put_identity(identity(email: nil))
      assert {:error, :email_required} = Accounts.sso_sign_in("google", %{}, %{})
    end

    test "adapter error is passed through" do
      Stub.put_error(:provider_down)
      assert {:error, :provider_down} = Accounts.sso_sign_in("google", %{}, %{})
    end
  end

  describe "configured_providers/0" do
    test "returns only configured providers in display order" do
      Application.put_env(:perfect_paper, :oauth_providers, %{
        "github" => [client_id: "x", client_secret: "y"],
        "google" => [client_id: "x", client_secret: "y"]
      })

      on_exit(fn -> Application.put_env(:perfect_paper, :oauth_providers, %{}) end)

      assert Accounts.configured_providers() == ["google", "github"]
    end
  end
end
