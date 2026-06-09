defmodule PerfectPaperWeb.UserAuthDeactivationTest do
  use PerfectPaperWeb.ConnCase, async: true
  alias PerfectPaper.Accounts
  alias PerfectPaperWeb.UserAuth
  import PerfectPaper.AccountsFixtures

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, PerfectPaperWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{conn: conn}
  end

  test "an active user resolves a scope with their user", %{conn: conn} do
    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])
    assert conn.assigns.current_scope.user.id == user.id
  end

  test "a deactivated user is not authenticated (even with a live token)", %{conn: conn} do
    user = user_fixture()
    {:ok, _} = Accounts.deactivate_user(user)
    # Mint the token AFTER deactivation so the block is proven by the
    # deactivated_at guard, not merely by deactivation having deleted tokens.
    token = Accounts.generate_user_session_token(user)
    conn = conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])
    # Scope.for_user(nil) is nil — the unauthenticated state.
    assert is_nil(conn.assigns.current_scope)
  end
end
