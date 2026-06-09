defmodule PerfectPaperWeb.OAuthControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Accounts.OAuth.Stub

  describe "GET /auth/:provider" do
    test "redirects to the provider authorize url", %{conn: conn} do
      conn = get(conn, ~p"/auth/google")
      assert redirected_to(conn) =~ "example.test/auth/google"
      assert get_session(conn, :oauth_session_params)
    end
  end

  describe "GET /auth/:provider/callback" do
    test "logs in on a successful identity", %{conn: conn} do
      email = unique_user_email()

      Stub.put_identity(%{
        provider: "google",
        uid: "u1",
        email: email,
        email_verified: true,
        name: "X"
      })

      conn =
        conn
        |> init_test_session(%{oauth_session_params: %{state: "s"}})
        |> get(~p"/auth/google/callback", %{"code" => "abc", "state" => "s"})

      assert redirected_to(conn) == ~p"/new"
      assert get_session(conn, :user_token)
    end

    test "redirects to login with a flash when the email is already taken", %{conn: conn} do
      user = user_fixture()

      Stub.put_identity(%{
        provider: "google",
        uid: "u2",
        email: user.email,
        email_verified: false,
        name: "X"
      })

      conn =
        conn
        |> init_test_session(%{oauth_session_params: %{state: "s"}})
        |> get(~p"/auth/google/callback", %{"code" => "abc", "state" => "s"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already"
    end

    test "a callback with no stored session is rejected cleanly (no crash)", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{})
        |> get(~p"/auth/google/callback", %{"code" => "abc", "state" => "s"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end
  end
end
