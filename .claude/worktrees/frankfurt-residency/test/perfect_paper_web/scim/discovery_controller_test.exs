defmodule PerfectPaperWeb.Scim.DiscoveryControllerTest do
  use PerfectPaperWeb.ConnCase, async: true
  alias PerfectPaper.Scim
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    org = organization_fixture(user)
    {:ok, token} = Scim.generate_scim_token(org, user)
    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{token}"), org: org}
  end

  test "ServiceProviderConfig advertises patch + filter, not bulk/sort", %{conn: conn} do
    body = conn |> get("/scim/v2/ServiceProviderConfig") |> json_response(200)
    assert body["patch"]["supported"] == true
    assert body["filter"]["supported"] == true
    assert body["filter"]["maxResults"] == 100
    assert body["bulk"]["supported"] == false
    assert body["sort"]["supported"] == false
  end

  test "ResourceTypes lists User and Group", %{conn: conn} do
    body = conn |> get("/scim/v2/ResourceTypes") |> json_response(200)
    names = Enum.map(body["Resources"], & &1["name"])
    assert "User" in names and "Group" in names
  end

  test "Schemas returns the core User + Group schemas", %{conn: conn} do
    body = conn |> get("/scim/v2/Schemas") |> json_response(200)
    ids = Enum.map(body["Resources"], & &1["id"])
    assert "urn:ietf:params:scim:schemas:core:2.0:User" in ids
    assert "urn:ietf:params:scim:schemas:core:2.0:Group" in ids
  end

  test "without a token -> 401", %{} do
    conn = build_conn() |> get("/scim/v2/ServiceProviderConfig")
    assert conn.status == 401
    assert conn.resp_body =~ "urn:ietf:params:scim:api:messages:2.0:Error"
  end
end
