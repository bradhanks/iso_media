defmodule PerfectPaper.SSOSignInTest do
  # async: false because make_sso_config/0 writes Application env (:sso_adapters),
  # which is global. Running sync prevents cross-test contamination.
  use PerfectPaper.DataCase, async: false

  import Ecto.Query, warn: false
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  alias PerfectPaper.{Authz, SSO, Accounts, Repo}
  alias PerfectPaper.Accounts.{UserToken, UserIdentity, User}
  alias PerfectPaper.Organizations.Membership

  @valid_oidc_attrs %{
    protocol: :oidc,
    email_domain: "acme.test",
    oidc_tenant_id: "tenant-abc",
    oidc_client_id: "client-123",
    oidc_client_secret: "super-secret"
  }

  # Creates an org + verified+enabled OIDC config for "acme.test" and
  # wires the Stub adapter for the test process.
  defp make_sso_config do
    Application.put_env(:perfect_paper, :sso_adapters, oidc: PerfectPaper.SSO.Stub)
    on_exit(fn -> Application.delete_env(:perfect_paper, :sso_adapters) end)

    owner = user_fixture()
    org = organization_fixture(owner)
    owner_scope = Authz.load_subject(owner)

    {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
    {:ok, _} = SSO.verify_domain(org, owner_scope)
    {:ok, config} = SSO.enable_sso(org, owner_scope, true)

    {org, config}
  end

  # Sets the process-local Stub identity and returns it.
  defp stub_identity(attrs) do
    identity =
      Map.merge(
        %{
          provider: "stub",
          uid: "stub-uid-1",
          email: "user@acme.test",
          email_verified: true,
          name: "Test User"
        },
        Map.new(attrs)
      )

    Process.put(:sso_stub_identity, identity)
    identity
  end

  defp member_of_org?(org, user) do
    Repo.get_by(Membership, organization_id: org.id, user_id: user.id) != nil
  end

  # ── authorize_url ─────────────────────────────────────────────────────────

  describe "authorize_url/1" do
    test "returns {:ok, %{url, session_params}} via the Stub adapter" do
      {_org, config} = make_sso_config()
      assert {:ok, %{url: url, session_params: params}} = SSO.authorize_url(config)
      assert is_binary(url)
      assert is_map(params)
    end
  end

  # ── sign_in/3 ─────────────────────────────────────────────────────────────

  describe "sign_in/3" do
    test "new verified email creates user and adds org membership" do
      {org, config} = make_sso_config()
      stub_identity(email: "new@acme.test", uid: "new-uid-1")

      assert {:ok, user} = SSO.sign_in(config, %{}, %{})
      assert user.email == "new@acme.test"
      assert member_of_org?(org, user)
    end

    test "a deactivated user cannot sign in (fails closed, no membership reinstatement)" do
      {org, config} = make_sso_config()
      stub_identity(email: "gone@acme.test", uid: "gone-uid")

      {:ok, user} = SSO.sign_in(config, %{}, %{})
      {:ok, _} = Accounts.deactivate_user(user)
      # Strip the membership so we can prove sign_in does NOT silently reinstate it.
      Repo.delete_all(from m in Membership, where: m.user_id == ^user.id)

      assert {:error, :account_deactivated} = SSO.sign_in(config, %{}, %{})
      refute member_of_org?(org, user)
    end

    test "returning user (same provider+uid) signs in; membership stays exactly one row" do
      {org, config} = make_sso_config()
      stub_identity(email: "returning@acme.test", uid: "returning-uid")

      {:ok, user_first} = SSO.sign_in(config, %{}, %{})
      assert member_of_org?(org, user_first)

      {:ok, user_second} = SSO.sign_in(config, %{}, %{})
      assert user_first.id == user_second.id

      memberships =
        Repo.all(
          from m in Membership,
            where: m.organization_id == ^org.id and m.user_id == ^user_first.id
        )

      assert length(memberships) == 1
    end

    test "domain mismatch returns :domain_mismatch; no user, identity, or membership is created" do
      {org, config} = make_sso_config()
      stub_identity(email: "victim@evil.test", uid: "evil-uid")

      assert {:error, :domain_mismatch} = SSO.sign_in(config, %{}, %{})

      refute Repo.get_by(Membership, organization_id: org.id)
      refute Repo.get_by(UserIdentity, provider: "stub", provider_uid: "evil-uid")
    end

    test "mixed-case Entra-style email (Alice@ACME.test) matches stored lowercase domain" do
      {org, config} = make_sso_config()
      # config.email_domain is "acme.test"; Entra returns `Alice@ACME.test`
      stub_identity(email: "Alice@ACME.test", uid: "alice-uid")

      assert {:ok, user} = SSO.sign_in(config, %{}, %{})
      assert member_of_org?(org, user)
    end

    # ── Rule 1: invited guest ─────────────────────────────────────────────

    test "Rule 1 — invited guest is linked and promoted, added to org" do
      {org, config} = make_sso_config()
      {:ok, guest} = Accounts.find_or_create_guest("bob@acme.test")

      # Verify it is truly a guest record
      assert is_nil(guest.hashed_password)
      assert is_nil(guest.confirmed_at)
      assert is_nil(guest.promoted_at)

      stub_identity(email: "bob@acme.test", uid: "bob-uid", email_verified: true)
      assert {:ok, promoted_user} = SSO.sign_in(config, %{}, %{})
      assert promoted_user.id == guest.id

      # Account is now fully confirmed and promoted
      reloaded = Repo.get!(User, promoted_user.id)
      assert reloaded.confirmed_at != nil
      assert reloaded.promoted_at != nil

      assert member_of_org?(org, promoted_user)
    end

    # ── Rule 2: squatter neutralization ──────────────────────────────────

    test "Rule 2 — squatter with password is neutralized: hashed_password nil, all sessions revoked, SSO identity linked" do
      {org, config} = make_sso_config()

      # Register an unverified password user squatting on the corp email address.
      {:ok, squatter} =
        Accounts.register_user_with_password(%{
          email: "eve@acme.test",
          password: "squatting_pw_12345"
        })

      assert squatter.hashed_password != nil

      # Create a session token — we'll assert it is gone after sign_in.
      _session_token = Accounts.generate_user_session_token(squatter)

      session_count_before =
        Repo.aggregate(
          from(t in UserToken,
            where: t.user_id == ^squatter.id and t.context == "session"
          ),
          :count
        )

      assert session_count_before == 1

      stub_identity(email: "eve@acme.test", uid: "eve-uid", email_verified: true)
      assert {:ok, sso_user} = SSO.sign_in(config, %{}, %{})
      assert sso_user.id == squatter.id

      # hashed_password MUST be nil after neutralization
      reloaded = Repo.get!(User, squatter.id)
      assert is_nil(reloaded.hashed_password)

      # ALL session tokens for the squatter MUST be revoked
      session_count_after =
        Repo.aggregate(
          from(t in UserToken,
            where: t.user_id == ^squatter.id and t.context == "session"
          ),
          :count
        )

      assert session_count_after == 0

      assert member_of_org?(org, sso_user)
    end

    # ── Social-OAuth squatter unchanged ──────────────────────────────────

    test "social-OAuth squatter (trusted_domain: false) returns :email_taken; password untouched" do
      # Create an unverified password user
      {:ok, squatter} =
        Accounts.register_user_with_password(%{
          email: "social_squatter@example.test",
          password: "squatting_pw_12345"
        })

      assert squatter.hashed_password != nil

      # Simulate a generic OAuth callback with a verified email — but NOT via
      # enterprise SSO, so trusted_domain is false.
      identity = %{
        provider: "google",
        uid: "google-uid-999",
        email: "social_squatter@example.test",
        email_verified: true,
        name: "Social"
      }

      assert {:error, :email_taken} =
               Accounts.resolve_sso_identity(identity, trusted_domain: false)

      # The squatter's password must remain intact
      reloaded = Repo.get!(User, squatter.id)
      assert reloaded.hashed_password != nil
    end
  end
end
