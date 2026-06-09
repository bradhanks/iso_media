defmodule PerfectPaperWeb.Scim.UserControllerTest do
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
    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{token}"), org: org, owner: owner}
  end

  test "Test-Connection: GET /Users with a no-match filter returns 200 empty ListResponse", %{
    conn: conn
  } do
    body =
      conn
      |> get(~s(/scim/v2/Users?filter=userName eq "nobody-#{Ecto.UUID.generate()}@acme.com"))
      |> json_response(200)

    assert body["totalResults"] == 0
    assert body["Resources"] == []
    assert "urn:ietf:params:scim:api:messages:2.0:ListResponse" in body["schemas"]
  end

  test "POST /Users provisions and returns 201", %{conn: conn} do
    body =
      conn
      |> post("/scim/v2/Users", %{
        "userName" => "alice@acme.com",
        "externalId" => "ext-1",
        "active" => true
      })
      |> json_response(201)

    assert body["userName"] == "alice@acme.com"
    assert body["active"] == true
  end

  test "GET /Users filter finds the provisioned user case-insensitively", %{conn: conn} do
    conn |> post("/scim/v2/Users", %{"userName" => "alice@acme.com", "externalId" => "e"})

    body =
      conn |> get(~s(/scim/v2/Users?filter=userName eq "Alice@Acme.com")) |> json_response(200)

    assert body["totalResults"] == 1
    assert hd(body["Resources"])["userName"] == "alice@acme.com"
  end

  test "GET /Users/:id returns the user; missing -> 404 SCIM error", %{conn: conn} do
    %{"id" => id} =
      conn
      |> post("/scim/v2/Users", %{"userName" => "alice@acme.com", "externalId" => "e"})
      |> json_response(201)

    assert conn |> get("/scim/v2/Users/#{id}") |> json_response(200)
    err = conn |> get("/scim/v2/Users/#{Ecto.UUID.generate()}") |> json_response(404)
    assert "urn:ietf:params:scim:api:messages:2.0:Error" in err["schemas"]
  end

  test "PATCH active:false deactivates; DELETE soft-deactivates (204)", %{conn: conn} do
    %{"id" => id} =
      conn
      |> post("/scim/v2/Users", %{"userName" => "alice@acme.com", "externalId" => "e"})
      |> json_response(201)

    patch_body = %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
      "Operations" => [%{"op" => "replace", "value" => %{"active" => false}}]
    }

    assert %{"active" => false} =
             conn |> patch("/scim/v2/Users/#{id}", patch_body) |> json_response(200)

    assert conn |> delete("/scim/v2/Users/#{id}") |> response(204)
  end

  test "PATCH deactivating the org owner -> 400 mutability", %{conn: conn, owner: owner} do
    patch_body = %{"Operations" => [%{"op" => "replace", "path" => "active", "value" => "false"}]}
    err = conn |> patch("/scim/v2/Users/#{owner.id}", patch_body) |> json_response(400)
    assert err["scimType"] == "mutability"
  end
end
