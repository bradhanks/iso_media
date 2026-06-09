defmodule PerfectPaperWeb.TeamsController do
  @moduledoc """
  Web surface for the Microsoft Teams bot:

    * `messages/2` — the **public** Bot Framework messaging endpoint. It is
      authenticated SOLELY by the inbound Bot Framework JWT (no cookie/session,
      no CSRF). Every request is verified via `Teams.TokenVerifier.verify/2`
      (signature + issuer/audience + `serviceUrl` replay defense); only a valid
      token reaches `Teams.handle_activity/2`. A failed verification returns a
      bare `401`.
    * `link/2` — the deep-link fallback redeem. Browser/authenticated: binds the
      logged-in user's account to the Teams identity carried in a short-lived
      signed token.
    * `manifest/2` — downloads the sideload-ready Teams app package (a ZIP of
      `manifest.json` + icons) as `application/zip`.
  """
  use PerfectPaperWeb, :controller

  alias PerfectPaper.Teams
  alias PerfectPaper.Teams.{Activity, Manifest, TokenVerifier}

  @doc """
  Public Bot Framework messaging endpoint. Verifies the inbound JWT against the
  request's `serviceUrl`; on success, parses and dispatches the Activity and
  returns `200`; on any verification failure returns `401`.
  """
  @spec messages(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def messages(conn, params) do
    auth = List.first(get_req_header(conn, "authorization"))
    service_url = params["serviceUrl"]

    case TokenVerifier.verify(auth, service_url) do
      {:ok, _claims} ->
        Teams.handle_activity(Activity.parse(params), %{})
        send_resp(conn, 200, "")

      {:error, _reason} ->
        send_resp(conn, 401, "")
    end
  end

  @doc """
  Deep-link redeem: binds the logged-in user to the Teams identity in `token`,
  then redirects back to the account page with a flash.
  """
  @spec link(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def link(conn, %{"token" => token}) do
    case Teams.redeem_link_token(conn.assigns.current_scope.user, token) do
      {:ok, _link} ->
        conn
        |> put_flash(:info, "Microsoft Teams connected.")
        |> redirect(to: ~p"/account")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That Teams link expired or is invalid.")
        |> redirect(to: ~p"/account")
    end
  end

  def link(conn, _params) do
    conn
    |> put_flash(:error, "That Teams link is missing or invalid.")
    |> redirect(to: ~p"/account")
  end

  @doc "Downloads the sideload-ready Teams app package as an `application/zip` attachment."
  @spec manifest(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def manifest(conn, _params) do
    conn
    |> put_resp_content_type("application/zip")
    |> put_resp_header("content-disposition", ~s(attachment; filename="perfectpaper-teams.zip"))
    |> send_resp(200, Manifest.package())
  end
end
