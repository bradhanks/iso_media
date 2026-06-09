defmodule PerfectPaperWeb.SsoController do
  @moduledoc """
  Drives the enterprise SSO redirect round-trip for organization login.

  `request/2` looks up the org's enabled+verified SSO config, builds the IdP
  authorize URL, stores the returned `session_params` in a per-org MAP keyed by
  `org_id` (`:sso_requests`), and redirects to the IdP.

  `callback/2` reads the org's `session_params` from `:sso_requests`, calls
  `SSO.sign_in/3`, and on both success and terminal failure deletes the org_id
  key so stale entries never accumulate in the session cookie.

  Storing session_params per-org (not a flat key) means concurrent tabs — one
  for org A, one for org B — never clobber each other.
  """
  use PerfectPaperWeb, :controller

  alias PerfectPaper.SSO
  alias PerfectPaperWeb.UserAuth

  @doc """
  Initiates SSO for the given org. Redirects to the IdP authorization URL.

  Stores `session_params` under `sso_requests[org_id]` in the browser session
  to allow concurrent in-flight SSO flows for different orgs without clobbering.
  """
  @spec request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request(conn, %{"org_id" => org_id}) do
    case SSO.get_config_by_org_id(org_id) do
      nil ->
        conn
        |> put_flash(:error, "SSO is not configured or not enabled for this organization.")
        |> redirect(to: ~p"/users/log-in")

      config ->
        case SSO.authorize_url(config) do
          {:ok, %{url: url, session_params: session_params}} ->
            existing = get_session(conn, :sso_requests) || %{}

            conn
            |> put_session(:sso_requests, Map.put(existing, org_id, session_params))
            |> redirect(external: url)

          {:error, _reason} ->
            conn
            |> put_flash(:error, "Could not reach the identity provider. Please try again.")
            |> redirect(to: ~p"/users/log-in")
        end
    end
  end

  @doc """
  Handles the IdP callback for the given org.

  Reads the stored `session_params` from `sso_requests[org_id]`. If missing
  (expired or direct navigation), flashes an error and redirects to login.

  On both success and terminal failure the org_id key is deleted from
  `:sso_requests` to prevent stale request IDs and cookie bloat.
  """
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"org_id" => org_id} = params) do
    existing = get_session(conn, :sso_requests) || %{}
    session_params = existing[org_id]

    if is_nil(session_params) do
      conn
      |> put_session(:sso_requests, Map.delete(existing, org_id))
      |> put_flash(:error, "Your sign-in session expired. Please try again.")
      |> redirect(to: ~p"/users/log-in")
    else
      # Clean the org_id key before branching — we delete on BOTH success and failure.
      conn = put_session(conn, :sso_requests, Map.delete(existing, org_id))

      case SSO.get_config_by_org_id(org_id) do
        nil ->
          conn
          |> put_flash(:error, "SSO is not configured or not enabled for this organization.")
          |> redirect(to: ~p"/users/log-in")

        config ->
          case SSO.sign_in(config, params, session_params) do
            {:ok, user} ->
              UserAuth.log_in_user(conn, user)

            {:error, reason} ->
              conn
              |> put_flash(:error, sign_in_error_message(reason))
              |> redirect(to: ~p"/users/log-in")
          end
      end
    end
  end

  defp sign_in_error_message(:domain_mismatch),
    do: "Your email address is not in the allowed domain for this organization."

  defp sign_in_error_message(:email_required),
    do: "The identity provider did not return an email address. Please contact your IT admin."

  defp sign_in_error_message(:email_taken),
    do: "That email already has an account. Log in, then link this provider in Settings."

  defp sign_in_error_message(_other),
    do: "Sign-in failed. Please try again or contact your IT admin."
end
