defmodule PerfectPaperWeb.ScimLiveTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup %{conn: conn} do
    owner = user_fixture()
    org = organization_fixture(owner)
    %{conn: log_in_user(conn, owner), org: org, owner: owner}
  end

  test "admin sees the SCIM base URL", %{conn: conn, org: org} do
    {:ok, _lv, html} = live(conn, ~p"/orgs/#{org.id}/scim")
    assert html =~ "/scim/v2"
    assert html =~ "No token configured."
  end

  test "admin can generate a token (shown once)", %{conn: conn, org: org} do
    {:ok, lv, _html} = live(conn, ~p"/orgs/#{org.id}/scim")
    html = lv |> element("#scim-generate-token") |> render_click()
    assert html =~ "scim_"
    assert html =~ "will not be shown again"
  end

  test "admin can revoke", %{conn: conn, org: org, owner: owner} do
    {:ok, _} = PerfectPaper.Scim.generate_scim_token(org, owner)
    {:ok, lv, _html} = live(conn, ~p"/orgs/#{org.id}/scim")
    html = lv |> element("#scim-revoke-token") |> render_click()
    assert html =~ "No token configured."
  end

  test "non-admin is redirected", %{conn: conn, org: org} do
    other = user_fixture()

    assert {:error, {:live_redirect, %{to: path}}} =
             conn |> log_in_user(other) |> live(~p"/orgs/#{org.id}/scim")

    refute path =~ "/scim"
  end
end
