defmodule PerfectPaperWeb.Audit.MalformedIdTest do
  @moduledoc "Audit fix: a malformed (non-UUID) id must yield a clean 4xx, never an Ecto.Query.CastError 500."
  use PerfectPaperWeb.ConnCase, async: true
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  alias PerfectPaper.Scim

  test "public SSO start with a non-UUID org_id does not 500", %{conn: conn} do
    conn = get(conn, "/sso/not-a-uuid/start")
    refute conn.status == 500
  end

  test "REST history show with a non-UUID id returns 404, not 500", %{conn: conn} do
    user = user_fixture()
    {:ok, raw, _} = PerfectPaper.ApiKeys.generate(user, "ci")

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("accept", "application/json")
      |> get("/api/history/not-a-uuid")

    assert conn.status == 404
  end

  test "SCIM Users/Groups by non-UUID id returns the 404 SCIM envelope, not 500", %{conn: conn} do
    owner = user_fixture()
    org = organization_fixture(owner)
    {:ok, token} = Scim.generate_scim_token(org, owner)

    conn = put_req_header(conn, "authorization", "Bearer #{token}")

    u = get(conn, "/scim/v2/Users/not-a-uuid")
    assert u.status == 404

    g = get(conn, "/scim/v2/Groups/not-a-uuid")
    assert g.status == 404
  end
end
