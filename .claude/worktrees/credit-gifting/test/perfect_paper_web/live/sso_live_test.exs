defmodule PerfectPaperWeb.SsoLiveTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  alias PerfectPaper.{Authz, SSO}

  defp configure_oidc(org, user) do
    {:ok, config} =
      SSO.configure_sso(org, Authz.load_subject(user), %{
        protocol: :oidc,
        email_domain: "acme.test",
        oidc_tenant_id: "tenant-abc",
        oidc_client_id: "client-123",
        oidc_client_secret: "super-secret-value"
      })

    config
  end

  # ---------------------------------------------------------------------------
  # Mount / access
  # ---------------------------------------------------------------------------

  describe "mount" do
    test "redirects when not logged in", %{conn: conn} do
      org_id = Ecto.UUID.generate()
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/orgs/#{org_id}/sso")
      assert path =~ "/users/log-in"
    end

    test "redirects (not crashes) on a malformed, non-UUID org id", %{conn: conn} do
      user = user_fixture()

      {:error, {:live_redirect, %{to: path}}} =
        conn |> log_in_user(user) |> live("/orgs/not-a-uuid/sso")

      refute path =~ "/sso"
    end

    test "redirects a non-admin away", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)
      stranger = user_fixture()

      {:error, {:live_redirect, %{to: path}}} =
        conn |> log_in_user(stranger) |> live(~p"/orgs/#{org.id}/sso")

      refute path =~ "/sso"
    end

    test "renders the page for an org admin", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)
      {:ok, _lv, html} = conn |> log_in_user(owner) |> live(~p"/orgs/#{org.id}/sso")
      assert html =~ "Single sign-on"
    end
  end

  # ---------------------------------------------------------------------------
  # Configure
  # ---------------------------------------------------------------------------

  describe "configure" do
    test "configuring OIDC stores the config and reports the secret as set", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/orgs/#{org.id}/sso")

      html =
        lv
        |> form("#sso-config-form", %{
          "config" => %{
            "protocol" => "oidc",
            "email_domain" => "acme.test",
            "oidc_tenant_id" => "tenant-abc",
            "oidc_client_id" => "client-123",
            "oidc_client_secret" => "super-secret-value"
          }
        })
        |> render_submit()

      assert html =~ "acme.test"
      # Secret reported only as "set", never the raw value
      refute html =~ "super-secret-value"
      assert SSO.get_config(org).oidc_client_id == "client-123"
    end

    test "invalid config (public domain) shows an error", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/orgs/#{org.id}/sso")

      html =
        lv
        |> form("#sso-config-form", %{
          "config" => %{
            "protocol" => "oidc",
            "email_domain" => "gmail.com",
            "oidc_tenant_id" => "t",
            "oidc_client_id" => "c",
            "oidc_client_secret" => "s"
          }
        })
        |> render_submit()

      assert html =~ "corporate domain"
    end
  end

  # ---------------------------------------------------------------------------
  # Verify domain
  # ---------------------------------------------------------------------------

  describe "verify domain" do
    test "verifying marks the domain verified", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)
      configure_oidc(org, owner)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/orgs/#{org.id}/sso")

      html =
        lv
        |> element("#sso-verify-domain")
        |> render_click()

      assert html =~ "Verified"
      assert SSO.get_config(org).domain_verified
    end
  end

  # ---------------------------------------------------------------------------
  # Enable toggle
  # ---------------------------------------------------------------------------

  describe "enable" do
    test "enable button is disabled until the domain is verified", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)
      configure_oidc(org, owner)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/orgs/#{org.id}/sso")

      assert has_element?(lv, "#sso-enable[disabled]")
    end

    test "enabling SSO after verification flips enabled", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)
      configure_oidc(org, owner)
      SSO.verify_domain(org, Authz.load_subject(owner))

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/orgs/#{org.id}/sso")

      refute has_element?(lv, "#sso-enable[disabled]")

      lv |> element("#sso-enable") |> render_click()

      assert SSO.get_config(org).enabled
    end
  end

  # ---------------------------------------------------------------------------
  # Secret never rendered
  # ---------------------------------------------------------------------------

  test "the raw secret is never rendered on the page", %{conn: conn} do
    owner = user_fixture()
    org = organization_fixture(owner)
    configure_oidc(org, owner)

    {:ok, _lv, html} = conn |> log_in_user(owner) |> live(~p"/orgs/#{org.id}/sso")
    refute html =~ "super-secret-value"
  end
end
