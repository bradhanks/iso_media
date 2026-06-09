defmodule PerfectPaperWeb.Plugs.ApiAuthTest do
  use PerfectPaperWeb.ConnCase, async: true

  alias PerfectPaperWeb.Plugs.ApiAuth

  import PerfectPaper.AccountsFixtures

  test "assigns current_user for a valid API key", %{conn: conn} do
    user = user_fixture()
    {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(user, "ci")

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
      |> ApiAuth.call(ApiAuth.init([]))

    assert conn.assigns.current_user.id == user.id
    refute conn.halted
  end

  test "halts with 401 and a detail envelope when the header is missing", %{conn: conn} do
    conn = ApiAuth.call(conn, ApiAuth.init([]))
    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"detail" => "Not authenticated"}
  end

  test "halts with 401 for an invalid token", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer pp_not_a_real_key")
      |> ApiAuth.call(ApiAuth.init([]))

    assert conn.halted
    assert conn.status == 401
  end
end
