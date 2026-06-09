defmodule PerfectPaperWeb.TeamsControllerTest do
  # async: false — the 401 test mutates the global :teams_token_verifier config.
  use PerfectPaperWeb.ConnCase, async: false
  alias PerfectPaper.{Teams, Accounts}
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    owner = user_fixture()
    org = organization_fixture(owner)
    scope = PerfectPaper.Accounts.Scope.for_user(owner)

    {:ok, _} =
      PerfectPaper.SSO.configure_sso(org, scope, %{
        protocol: :oidc,
        email_domain: "acme.com",
        oidc_tenant_id: "tenant-1",
        oidc_client_id: "c",
        oidc_client_secret: "s"
      })

    {:ok, _} = PerfectPaper.SSO.verify_domain(org, scope)
    {:ok, _} = PerfectPaper.SSO.enable_sso(org, scope, true)

    {:ok, _} =
      Accounts.create_identity(owner, %{
        provider: "oidc:#{org.id}",
        provider_uid: "aad-1",
        provider_email: owner.email
      })

    %{owner: owner, org: org}
  end

  defp install_params(oid, tenant) do
    %{
      "type" => "conversationUpdate",
      "from" => %{"aadObjectId" => oid},
      "channelData" => %{"tenant" => %{"id" => tenant}},
      "serviceUrl" => "https://smba.example/",
      "conversation" => %{"id" => "c1"},
      "recipient" => %{"id" => "bot"}
    }
  end

  test "valid token (stub accepts) → 200 and links the user", %{conn: conn, owner: owner} do
    conn = post(conn, ~p"/teams/messages", install_params("aad-1", "tenant-1"))
    assert response(conn, 200)
    assert Teams.get_link_by_user(owner.id)
  end

  test "rejected token → 401 and no link created", %{conn: conn, owner: owner} do
    prev = Application.get_env(:perfect_paper, :teams_token_verifier)

    Application.put_env(
      :perfect_paper,
      :teams_token_verifier,
      PerfectPaper.Teams.TokenVerifier.AlwaysReject
    )

    on_exit(fn -> Application.put_env(:perfect_paper, :teams_token_verifier, prev) end)

    conn = post(conn, ~p"/teams/messages", install_params("aad-1", "tenant-1"))
    assert response(conn, 401)
    refute Teams.get_link_by_user(owner.id)
  end
end
