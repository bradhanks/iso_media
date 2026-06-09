defmodule PerfectPaper.SSOTest do
  use PerfectPaper.DataCase, async: true

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  alias PerfectPaper.{Authz, SSO}
  alias PerfectPaper.SSO.SsoConfig

  @valid_oidc_attrs %{
    protocol: :oidc,
    email_domain: "acme.test",
    oidc_tenant_id: "tenant-abc",
    oidc_client_id: "client-123",
    oidc_client_secret: "super-secret"
  }

  defp make_org_and_scopes do
    owner = user_fixture()
    admin = user_fixture()
    member = user_fixture()
    stranger = user_fixture()

    org = organization_fixture(owner)
    membership_fixture(org, admin, :admin)
    membership_fixture(org, member, :member)

    owner_scope = Authz.load_subject(owner)
    admin_scope = Authz.load_subject(admin)
    member_scope = Authz.load_subject(member)
    stranger_scope = Authz.load_subject(stranger)

    {org, owner_scope, admin_scope, member_scope, stranger_scope}
  end

  # ── configure_sso ─────────────────────────────────────────────────────────

  describe "configure_sso/3" do
    test "org owner can create an SSO config" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()

      assert {:ok, %SsoConfig{} = cfg} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      assert cfg.organization_id == org.id
      assert cfg.protocol == :oidc
      assert cfg.email_domain == "acme.test"
      assert cfg.oidc_client_id == "client-123"
      # these must NOT be set via configure_sso
      refute cfg.domain_verified
      refute cfg.enabled
    end

    test "org admin can create an SSO config" do
      {org, _owner, admin_scope, _member, _stranger} = make_org_and_scopes()

      assert {:ok, %SsoConfig{}} = SSO.configure_sso(org, admin_scope, @valid_oidc_attrs)
    end

    test "org owner can update an existing SSO config" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()

      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)

      assert {:ok, updated} =
               SSO.configure_sso(org, owner_scope, %{
                 @valid_oidc_attrs
                 | oidc_client_id: "new-client"
               })

      assert updated.oidc_client_id == "new-client"
    end

    test "plain member is unauthorized" do
      {org, _owner, _admin, member_scope, _stranger} = make_org_and_scopes()

      assert {:error, :unauthorized} = SSO.configure_sso(org, member_scope, @valid_oidc_attrs)
    end

    test "stranger (non-member) is unauthorized" do
      {org, _owner, _admin, _member, stranger_scope} = make_org_and_scopes()

      assert {:error, :unauthorized} = SSO.configure_sso(org, stranger_scope, @valid_oidc_attrs)
    end

    test "returns changeset error for invalid attrs" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()

      assert {:error, %Ecto.Changeset{}} =
               SSO.configure_sso(org, owner_scope, %{protocol: :oidc, email_domain: "acme.test"})
    end
  end

  # ── get_config ────────────────────────────────────────────────────────────

  describe "get_config/1" do
    test "returns nil when no config exists for org" do
      {org, _owner, _admin, _member, _stranger} = make_org_and_scopes()

      assert is_nil(SSO.get_config(org))
    end

    test "returns the config after configure_sso" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()

      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)

      assert %SsoConfig{} = SSO.get_config(org)
    end
  end

  # ── verify_domain ─────────────────────────────────────────────────────────

  describe "verify_domain/2" do
    test "org admin sets domain_verified to true" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)

      assert {:ok, %SsoConfig{domain_verified: true}} = SSO.verify_domain(org, owner_scope)
    end

    test "org admin (non-owner) can also verify the domain" do
      {org, owner_scope, admin_scope, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)

      assert {:ok, %SsoConfig{domain_verified: true}} = SSO.verify_domain(org, admin_scope)
    end

    test "non-admin is unauthorized" do
      {org, owner_scope, _admin, member_scope, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)

      assert {:error, :unauthorized} = SSO.verify_domain(org, member_scope)
    end

    test "returns error when no config exists" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()

      assert {:error, :not_found} = SSO.verify_domain(org, owner_scope)
    end
  end

  # ── enable_sso ────────────────────────────────────────────────────────────

  describe "enable_sso/3" do
    test "enabling before domain verification returns :domain_not_verified" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)

      assert {:error, :domain_not_verified} = SSO.enable_sso(org, owner_scope, true)
    end

    test "enabling after domain verification succeeds" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)

      assert {:ok, %SsoConfig{enabled: true}} = SSO.enable_sso(org, owner_scope, true)
    end

    test "disabling does not require domain_verified" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)
      {:ok, _} = SSO.enable_sso(org, owner_scope, true)

      assert {:ok, %SsoConfig{enabled: false}} = SSO.enable_sso(org, owner_scope, false)
    end

    test "non-admin is unauthorized regardless of verification state" do
      {org, owner_scope, _admin, member_scope, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)

      assert {:error, :unauthorized} = SSO.enable_sso(org, member_scope, true)
    end

    test "returns error when no config exists" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()

      assert {:error, :not_found} = SSO.enable_sso(org, owner_scope, true)
    end
  end

  # ── disable_sso ───────────────────────────────────────────────────────────

  describe "disable_sso/2" do
    test "org admin can disable SSO" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)
      {:ok, _} = SSO.enable_sso(org, owner_scope, true)

      assert {:ok, %SsoConfig{enabled: false}} = SSO.disable_sso(org, owner_scope)
    end

    test "non-admin is unauthorized" do
      {org, owner_scope, _admin, member_scope, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)

      assert {:error, :unauthorized} = SSO.disable_sso(org, member_scope)
    end
  end

  # ── config_for_email ──────────────────────────────────────────────────────

  describe "config_for_email/1" do
    test "returns config when enabled and verified and domain matches" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)
      {:ok, _} = SSO.enable_sso(org, owner_scope, true)

      assert %SsoConfig{email_domain: "acme.test"} =
               SSO.config_for_email("alice@acme.test")
    end

    test "returns nil when domain matches but not verified" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      # not verified, not enabled

      assert is_nil(SSO.config_for_email("alice@acme.test"))
    end

    test "returns nil when domain matches and verified but not enabled" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)
      # verified but not enabled

      assert is_nil(SSO.config_for_email("alice@acme.test"))
    end

    test "returns nil for unknown domain" do
      assert is_nil(SSO.config_for_email("alice@unknown.example"))
    end

    test "is case-insensitive on the email address" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)
      {:ok, _} = SSO.enable_sso(org, owner_scope, true)

      assert %SsoConfig{} = SSO.config_for_email("Alice@ACME.TEST")
    end

    test "returns nil when SSO is later disabled" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()
      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)
      {:ok, _} = SSO.enable_sso(org, owner_scope, true)
      {:ok, _} = SSO.disable_sso(org, owner_scope)

      assert is_nil(SSO.config_for_email("alice@acme.test"))
    end

    # Fix A — lookup normalization: config stored from "@Acme.test" matches "alice@acme.test"
    test "config stored with leading @ and mixed case is matched by normalized email lookup" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()

      attrs = %{
        protocol: :oidc,
        email_domain: "@Acme.test",
        oidc_tenant_id: "tenant-abc",
        oidc_client_id: "client-123",
        oidc_client_secret: "super-secret"
      }

      {:ok, _} = SSO.configure_sso(org, owner_scope, attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)
      {:ok, _} = SSO.enable_sso(org, owner_scope, true)

      assert %SsoConfig{email_domain: "acme.test"} = SSO.config_for_email("alice@acme.test")
    end
  end

  # Fix B — auto-revocation tests
  describe "configure_sso/3 auto-revocation on domain/cred change" do
    test "changing email_domain on a verified+enabled config resets domain_verified and enabled" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()

      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)
      {:ok, _} = SSO.enable_sso(org, owner_scope, true)

      # Change to a different domain
      {:ok, _} =
        SSO.configure_sso(org, owner_scope, %{@valid_oidc_attrs | email_domain: "beta.test"})

      reloaded = SSO.get_config(org)
      assert reloaded.email_domain == "beta.test"
      refute reloaded.domain_verified
      refute reloaded.enabled
    end

    test "changing an IdP credential (oidc_client_secret) on a verified+enabled config resets both flags" do
      {org, owner_scope, _admin, _member, _stranger} = make_org_and_scopes()

      {:ok, _} = SSO.configure_sso(org, owner_scope, @valid_oidc_attrs)
      {:ok, _} = SSO.verify_domain(org, owner_scope)
      {:ok, _} = SSO.enable_sso(org, owner_scope, true)

      {:ok, _} =
        SSO.configure_sso(org, owner_scope, %{
          @valid_oidc_attrs
          | oidc_client_secret: "new-secret"
        })

      reloaded = SSO.get_config(org)
      assert reloaded.oidc_client_secret == "new-secret"
      refute reloaded.domain_verified
      refute reloaded.enabled
    end
  end
end
