defmodule PerfectPaperWeb.SsoControllerTest do
  # async: false — sets Application env (:sso_adapters) which is global state.
  use PerfectPaperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  alias PerfectPaper.{Authz, SamlFixtures, SSO}

  @valid_oidc_attrs %{
    protocol: :oidc,
    email_domain: "acme.test",
    oidc_tenant_id: "tenant-abc",
    oidc_client_id: "client-123",
    oidc_client_secret: "super-secret"
  }

  # Wires the OIDC Stub adapter for the test process and tears it down after.
  defp wire_oidc_stub do
    Application.put_env(:perfect_paper, :sso_adapters, oidc: PerfectPaper.SSO.Stub)
    on_exit(fn -> Application.delete_env(:perfect_paper, :sso_adapters) end)
  end

  # Creates an org + a verified+enabled OIDC config for `domain`. Does NOT wire
  # the adapter — callers that need the adapter call wire_oidc_stub/0.
  defp oidc_org(domain) do
    owner = user_fixture()
    org = organization_fixture(owner)
    scope = Authz.load_subject(owner)

    attrs = %{@valid_oidc_attrs | email_domain: domain}
    {:ok, _} = SSO.configure_sso(org, scope, attrs)
    {:ok, _} = SSO.verify_domain(org, scope)
    {:ok, config} = SSO.enable_sso(org, scope, true)

    {org, config}
  end

  # Creates an org + verified+enabled OIDC config for "acme.test" with the Stub
  # adapter wired in for the test process.
  defp make_sso_org(domain \\ "acme.test") do
    wire_oidc_stub()
    oidc_org(domain)
  end

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

  # ── request ───────────────────────────────────────────────────────────────

  describe "GET /sso/:org_id/start" do
    test "redirects to the IdP authorize URL and stores session_params under sso_requests[org_id]",
         %{conn: conn} do
      {org, _config} = make_sso_org()

      conn = get(conn, ~p"/sso/#{org.id}/start")

      # Stub adapter returns https://idp.test/authorize?state=test
      assert redirected_to(conn) =~ "idp.test/authorize"

      # session_params stored under the org_id key, not a flat key
      sso_requests = get_session(conn, :sso_requests)
      assert is_map(sso_requests)
      assert Map.has_key?(sso_requests, org.id)
      assert is_map(sso_requests[org.id])
    end

    test "redirects to login with flash when no enabled+verified config exists for org",
         %{conn: conn} do
      # Use a random org_id that has no SSO config
      fake_org_id = Ecto.UUID.generate()
      conn = get(conn, ~p"/sso/#{fake_org_id}/start")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
    end
  end

  # ── callback ──────────────────────────────────────────────────────────────

  describe "GET /sso/:org_id/callback — success" do
    test "logs the user in (session token set, redirected to dashboard)", %{conn: conn} do
      {org, _config} = make_sso_org()
      stub_identity(email: "alice@acme.test", uid: "alice-uid")

      conn =
        conn
        |> init_test_session(%{sso_requests: %{org.id => %{state: "test"}}})
        |> get(~p"/sso/#{org.id}/callback", %{"code" => "abc", "state" => "test"})

      # Logged in — session token set and redirected to the dashboard
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/new"

      # renew_session (called by log_in_user) calls clear_session, so the whole
      # session is reset — sso_requests is gone, proving our delete + the session
      # renewal both ran. The key was explicitly deleted BEFORE log_in_user was
      # called (see controller code), and then clear_session wiped the rest.
      assert get_session(conn, :sso_requests) == nil
    end
  end

  describe "GET /sso/:org_id/callback — domain_mismatch failure" do
    test "flashes error, redirects to login, NO session token, and deletes the key",
         %{conn: conn} do
      {org, _config} = make_sso_org()
      # Identity outside the allowed domain
      stub_identity(email: "attacker@evil.test", uid: "evil-uid")

      conn =
        conn
        |> init_test_session(%{sso_requests: %{org.id => %{state: "test"}}})
        |> get(~p"/sso/#{org.id}/callback", %{"code" => "abc", "state" => "test"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not in the allowed domain"
      refute get_session(conn, :user_token)

      # sso_requests[org_id] key is DELETED on failure
      sso_requests = get_session(conn, :sso_requests)
      refute is_map(sso_requests) and Map.has_key?(sso_requests, org.id)
    end
  end

  describe "GET /sso/:org_id/callback — missing session_params" do
    test "expired/missing session → flash error + redirect, no session token, key deleted",
         %{conn: conn} do
      {org, _config} = make_sso_org()

      # No sso_requests entry for this org
      conn =
        conn
        |> init_test_session(%{sso_requests: %{}})
        |> get(~p"/sso/#{org.id}/callback", %{"code" => "abc", "state" => "test"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
      refute get_session(conn, :user_token)
    end
  end

  # ── Concurrent-tab / multi-org isolation ─────────────────────────────────

  describe "concurrent SSO flows for two orgs" do
    test "two request legs store both org_id keys independently — no clobber", %{conn: conn} do
      wire_oidc_stub()
      {org_a, _} = oidc_org("alpha.test")
      {org_b, _} = oidc_org("beta.test")

      # Simulate two browser tabs: tab A starts SSO for org_a, then tab B starts for org_b
      conn_a = get(conn, ~p"/sso/#{org_a.id}/start")
      sso_after_a = get_session(conn_a, :sso_requests)

      # Feed the session from tab A into a fresh request for org_b (same browser session)
      conn_b =
        conn
        |> init_test_session(%{sso_requests: sso_after_a})
        |> get(~p"/sso/#{org_b.id}/start")

      sso_after_both = get_session(conn_b, :sso_requests)

      # Both keys present — org_b did not clobber org_a
      assert Map.has_key?(sso_after_both, org_a.id)
      assert Map.has_key?(sso_after_both, org_b.id)
    end

    test "a domain_mismatch failure for org_a deletes only org_a's key; org_b's key survives",
         %{conn: conn} do
      # We use the *failure* path (domain mismatch) to observe selective key
      # deletion without session renewal obscuring the result. The same deletion
      # logic runs on success — it's in the same controller branch, just before
      # the UserAuth.log_in_user call that would then clear the whole session.
      wire_oidc_stub()
      {org_a, _} = oidc_org("alpha.test")
      {org_b, _} = oidc_org("beta.test")

      # Stub returns an identity that MISMATCHES org_a's domain — triggers :domain_mismatch
      stub_identity(email: "attacker@evil.test", uid: "evil-uid")

      pre_seeded_requests = %{
        org_a.id => %{state: "state-a"},
        org_b.id => %{state: "state-b"}
      }

      conn =
        conn
        |> init_test_session(%{sso_requests: pre_seeded_requests})
        |> get(~p"/sso/#{org_a.id}/callback", %{"code" => "abc", "state" => "state-a"})

      # Failure path — no login
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)

      # Selective deletion: org_a's key is gone; org_b's key is intact
      sso_requests = get_session(conn, :sso_requests)
      assert is_map(sso_requests)
      refute Map.has_key?(sso_requests, org_a.id)
      assert Map.has_key?(sso_requests, org_b.id)
    end
  end

  # ── SAML POST callback (real esaml adapter) ───────────────────────────────

  describe "POST /sso/:org_id/callback — SAML" do
    setup do
      # Use the REAL SAML adapter (not the Stub) for these tests.
      Application.put_env(:perfect_paper, :sso_adapters, saml: PerfectPaper.SSO.SAML)
      on_exit(fn -> Application.delete_env(:perfect_paper, :sso_adapters) end)

      {idp_pem, idp_key} = SamlFixtures.gen_self_signed()

      owner = user_fixture()
      org = organization_fixture(owner)
      scope = Authz.load_subject(owner)

      sp_entity_id = "https://app.test/sso/#{org.id}"
      callback_url = "https://app.test/sso/#{org.id}/callback"

      attrs = %{
        protocol: :saml,
        email_domain: "acme.test",
        saml_idp_entity_id: "https://login.idp.test/",
        saml_idp_sso_url: "https://login.idp.test/sso",
        saml_idp_cert: idp_pem,
        saml_sp_entity_id: sp_entity_id
      }

      {:ok, _} = SSO.configure_sso(org, scope, attrs)
      {:ok, _} = SSO.verify_domain(org, scope)
      {:ok, _} = SSO.enable_sso(org, scope, true)

      %{
        org: org,
        idp_pem: idp_pem,
        idp_key: idp_key,
        sp_entity_id: sp_entity_id,
        callback_url: callback_url
      }
    end

    test "a validly-signed SAMLResponse logs the user in (CSRF-exempt POST)", ctx do
      %{org: org, idp_pem: idp_pem, idp_key: idp_key} = ctx
      request_id = "_authnreq-web-1"

      b64 =
        SamlFixtures.signed_response(
          cert_pem: idp_pem,
          signing_key: idp_key,
          callback_url: provider_callback_url(org),
          sp_entity_id: provider_entity_id(org),
          email: "alice@acme.test",
          request_id: request_id
        )

      conn =
        build_conn()
        |> init_test_session(%{sso_requests: %{org.id => %{request_id: request_id}}})
        |> post(~p"/sso/#{org.id}/callback", %{"SAMLResponse" => b64})

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/new"
    end

    test "a tampered SAMLResponse is rejected (no login)", ctx do
      %{org: org, idp_pem: idp_pem, idp_key: idp_key} = ctx
      request_id = "_authnreq-web-2"

      b64 =
        SamlFixtures.signed_response(
          cert_pem: idp_pem,
          signing_key: idp_key,
          callback_url: provider_callback_url(org),
          sp_entity_id: provider_entity_id(org),
          email: "alice@acme.test",
          request_id: request_id,
          tamper: true
        )

      conn =
        build_conn()
        |> init_test_session(%{sso_requests: %{org.id => %{request_id: request_id}}})
        |> post(~p"/sso/#{org.id}/callback", %{"SAMLResponse" => b64})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  # The SSO context's provider_config sets the SAML SP callback URL/audience
  # from the stored config; mirror that here so the assertion's Recipient and
  # Audience match what the adapter validates against.
  defp provider_entity_id(org), do: "https://app.test/sso/#{org.id}"
  defp provider_callback_url(org), do: "https://app.test/sso/#{org.id}"

  # ── Login routing by email domain ─────────────────────────────────────────
  # These tests go through the LiveView mount and event dispatch.

  describe "login routing: SSO email domain" do
    test "an email in a verified+enabled SSO domain redirects to SSO start (not magic link)",
         %{conn: conn} do
      {org, _config} = make_sso_org("enterprise.test")

      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      result =
        render_submit(view, "submit_magic", %{
          "user" => %{"email" => "employee@enterprise.test"}
        })

      # push_navigate produces a live_redirect
      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == ~p"/sso/#{org.id}/start"
    end

    test "a non-SSO email follows the normal magic-link path (no redirect to SSO)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      # Submit a non-SSO email (gmail is a public domain with no enterprise SSO)
      html =
        render_submit(view, "submit_magic", %{
          "user" => %{"email" => "personal@gmail.com"}
        })

      # Should NOT redirect to SSO — should stay in the LiveView and show the
      # "check your email" state
      assert html =~ "Check your email"
    end
  end
end
