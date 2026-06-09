defmodule PerfectPaperWeb.OrgReviewSettingsLiveTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.{Chatbot, Organizations}

  setup do
    owner = user_fixture()
    {:ok, org} = Organizations.create_organization(owner, %{name: "Acme U"})
    %{owner: owner, org: org}
  end

  test "an org admin can view and save the org review prompt", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    {:ok, lv, _html} = live(log_in_user(conn, owner), ~p"/orgs/#{org.id}/review-settings")

    lv
    |> form("#review-settings-form", %{"body" => "Emphasize statistical rigor."})
    |> render_submit()

    assert Chatbot.get_prompt_layer(:organization, org.id) == "Emphasize statistical rigor."
  end

  test "a non-admin is redirected away", %{conn: conn, org: org} do
    stranger = user_fixture()

    assert {:error, {:live_redirect, %{to: "/new"}}} =
             live(log_in_user(conn, stranger), ~p"/orgs/#{org.id}/review-settings")
  end
end
