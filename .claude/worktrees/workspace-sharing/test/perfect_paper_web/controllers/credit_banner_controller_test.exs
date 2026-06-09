defmodule PerfectPaperWeb.CreditBannerControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "POST /credit-banner/dismiss sets the dismiss cookie and returns 204", %{conn: conn} do
    conn = post(conn, ~p"/credit-banner/dismiss")
    assert conn.status == 204
    assert conn.resp_cookies["pp_low_credit_dismissed"]
  end
end
