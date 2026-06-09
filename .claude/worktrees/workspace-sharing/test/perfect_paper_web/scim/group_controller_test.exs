defmodule PerfectPaperWeb.Scim.GroupControllerTest do
  use PerfectPaperWeb.ConnCase, async: true
  alias PerfectPaper.Scim
  alias PerfectPaper.Accounts.Scope
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup %{conn: conn} do
    owner = user_fixture()
    org = organization_fixture(owner)
    scope = Scope.for_user(owner)

    {:ok, _} =
      PerfectPaper.SSO.configure_sso(org, scope, %{
        protocol: :oidc,
        email_domain: "acme.com",
        oidc_tenant_id: "t",
        oidc_client_id: "c",
        oidc_client_secret: "s"
      })

    {:ok, _} = PerfectPaper.SSO.verify_domain(org, scope)
    {:ok, _} = PerfectPaper.SSO.enable_sso(org, scope, true)
    {:ok, token} = Scim.generate_scim_token(org, owner)

    {:ok, alice} =
      Scim.provision_user(org, %{external_id: "ext-1", user_name: "alice@acme.com", active: true})

    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{token}"), org: org, alice: alice}
  end

  test "Test-Connection: GET /Groups by displayName no match -> 200 empty", %{conn: conn} do
    body = conn |> get(~s(/scim/v2/Groups?filter=displayName eq "Nope")) |> json_response(200)
    assert body["totalResults"] == 0
    assert body["Resources"] == []
  end

  test "POST /Groups creates; PATCH add members repeated twice -> 204 + idempotent", %{
    conn: conn,
    alice: alice
  } do
    %{"id" => gid} =
      conn
      |> post("/scim/v2/Groups", %{"displayName" => "Engineering", "externalId" => "grp-1"})
      |> json_response(201)

    patch_body = %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
      "Operations" => [%{"op" => "add", "path" => "members", "value" => [%{"value" => alice.id}]}]
    }

    assert conn |> patch("/scim/v2/Groups/#{gid}", patch_body) |> response(204)
    # Entra repeats the same PATCH; must stay 204 and not duplicate membership.
    assert conn |> patch("/scim/v2/Groups/#{gid}", patch_body) |> response(204)

    body = conn |> get("/scim/v2/Groups/#{gid}") |> json_response(200)
    assert length(body["members"]) == 1
  end

  test "GET /Groups by externalId finds the created group", %{conn: conn} do
    conn |> post("/scim/v2/Groups", %{"displayName" => "Eng", "externalId" => "grp-9"})
    body = conn |> get(~s(/scim/v2/Groups?filter=externalId eq "grp-9")) |> json_response(200)
    assert body["totalResults"] == 1
  end

  test "DELETE /Groups/:id -> 204; missing -> 404", %{conn: conn} do
    %{"id" => gid} =
      conn
      |> post("/scim/v2/Groups", %{"displayName" => "X", "externalId" => "g"})
      |> json_response(201)

    assert conn |> delete("/scim/v2/Groups/#{gid}") |> response(204)
    err = conn |> get("/scim/v2/Groups/#{Ecto.UUID.generate()}") |> json_response(404)
    assert "urn:ietf:params:scim:api:messages:2.0:Error" in err["schemas"]
  end
end
