defmodule PerfectPaperWeb.ReferralControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "GET /join?ref=<code> stashes the code in the session and redirects to register", %{
    conn: conn
  } do
    conn = get(conn, ~p"/join?ref=pp-abc123")

    assert redirected_to(conn) == ~p"/users/register"
    assert get_session(conn, :referral_code) == "pp-abc123"
  end

  test "GET /join with no ref redirects to register and stores nothing", %{conn: conn} do
    conn = get(conn, ~p"/join")

    assert redirected_to(conn) == ~p"/users/register"
    assert get_session(conn, :referral_code) == nil
  end
end
