defmodule PerfectPaperWeb.AccountLiveTeamsTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias PerfectPaper.Teams

  setup :register_and_log_in_user

  defp link_user(user) do
    token =
      Teams.issue_link_token(%{
        aad_object_id: "aad-x",
        tenant_id: "t",
        conversation_reference: %{},
        service_url: "https://smba/"
      })

    {:ok, _} = Teams.redeem_link_token(user, token)
  end

  test "unlinked user sees the download link, no unlink button", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/account")
    assert html =~ ~s(id="teams-download")
    assert html =~ "Not connected"
    refute html =~ ~s(id="teams-unlink")
  end

  test "linked user sees Connected + can disconnect", %{conn: conn, user: user} do
    link_user(user)
    {:ok, lv, html} = live(conn, ~p"/account")
    assert html =~ ~s(id="teams-status")
    assert html =~ "Connected"
    assert Teams.get_link_by_user(user.id)

    html = lv |> element("#teams-unlink") |> render_click()
    assert html =~ "Not connected"
    refute Teams.get_link_by_user(user.id)
  end
end
