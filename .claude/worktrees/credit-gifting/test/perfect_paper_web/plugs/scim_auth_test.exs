defmodule PerfectPaperWeb.Plugs.ScimAuthTest do
  use PerfectPaperWeb.ConnCase, async: true
  alias PerfectPaperWeb.Plugs.ScimAuth
  alias PerfectPaper.Scim
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    user = user_fixture()
    org = organization_fixture(user)
    {:ok, token} = Scim.generate_scim_token(org, user)
    %{org: org, token: token}
  end

  test "assigns scim_org_id for a valid bearer token", %{conn: conn, org: org, token: token} do
    conn = conn |> put_req_header("authorization", "Bearer #{token}") |> ScimAuth.call([])
    refute conn.halted
    assert conn.assigns.scim_org_id == org.id
  end

  test "halts with 401 SCIM error when token is missing", %{conn: conn} do
    conn = ScimAuth.call(conn, [])
    assert conn.halted
    assert conn.status == 401
    assert conn.resp_body =~ "urn:ietf:params:scim:api:messages:2.0:Error"
  end

  test "halts with 401 when token is invalid", %{conn: conn} do
    conn = conn |> put_req_header("authorization", "Bearer scim_wrong") |> ScimAuth.call([])
    assert conn.halted
    assert conn.status == 401
  end
end
