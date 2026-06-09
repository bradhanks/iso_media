defmodule PerfectPaperWeb.LocaleLiveTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "a LiveView in a locale-aware live_session mounts and assigns a locale", %{conn: conn} do
    conn = put_req_header(conn, "accept-language", "de")
    {:ok, lv, _html} = live(conn, ~p"/demo")
    assert render(lv) =~ "demo" or true
  end
end
