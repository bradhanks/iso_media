defmodule PerfectPaperWeb.AdminLive.CreditsTest do
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Credits
  alias PerfectPaper.Credits.CreditEvent
  alias PerfectPaper.Repo

  defp log_in_admin(conn) do
    admin = user_fixture(%{email: "admin@perfectpaper.test"})
    {log_in_user(conn, admin), admin}
  end

  describe "access control" do
    test "redirects a non-admin authenticated user", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/credits")
    end

    test "allows an admin user", %{conn: conn} do
      {conn, _admin} = log_in_admin(conn)
      assert {:ok, _lv, html} = live(conn, ~p"/admin/credits")
      assert html =~ "Comp credits"
    end
  end

  describe "lookup and granting" do
    test "looks up a user and shows their balance", %{conn: conn} do
      {conn, _admin} = log_in_admin(conn)
      target = user_fixture()
      Credits.grant(target.id, 40, "seed")

      {:ok, lv, _html} = live(conn, ~p"/admin/credits")

      html =
        lv
        |> form("#lookup-form", %{email: target.email})
        |> render_submit()

      assert html =~ target.email
      assert html =~ "40"
    end

    test "shows an error for an unknown email", %{conn: conn} do
      {conn, _admin} = log_in_admin(conn)
      {:ok, lv, _html} = live(conn, ~p"/admin/credits")

      html =
        lv
        |> form("#lookup-form", %{email: "nobody@example.com"})
        |> render_submit()

      assert html =~ "No account found"
    end

    test "grants comp credits, updates the balance, and records attribution",
         %{conn: conn} do
      {conn, admin} = log_in_admin(conn)
      target = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin/credits")
      lv |> form("#lookup-form", %{email: target.email}) |> render_submit()

      html =
        lv
        |> form("#grant-form", %{grant: %{amount: "25", reason: "sorry for the outage"}})
        |> render_submit()

      assert html =~ "25"
      assert Credits.balance(target.id) == 25

      [event] = Repo.all(CreditEvent)
      assert event.metadata["kind"] == "comp"
      assert event.metadata["granted_by"] == admin.id
    end

    test "rejects a non-positive amount without writing", %{conn: conn} do
      {conn, _admin} = log_in_admin(conn)
      target = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin/credits")
      lv |> form("#lookup-form", %{email: target.email}) |> render_submit()

      lv
      |> form("#grant-form", %{grant: %{amount: "0", reason: "nope"}})
      |> render_submit()

      assert Credits.balance(target.id) == 0
    end
  end
end
