defmodule PerfectPaperWeb.OAuthController do
  @moduledoc """
  Drives the OAuth redirect round-trip for social sign-in. `request/2` sends the
  browser to the provider; `callback/2` exchanges the code, resolves the user
  through `Accounts.sso_sign_in/3`, and logs them in.
  """
  use PerfectPaperWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PerfectPaper.Accounts
  alias PerfectPaperWeb.UserAuth

  operation(:request,
    summary: "Initiate OAuth sign-in (browser redirect flow)",
    tags: ["Auth"],
    description: """
    Begins the OAuth authorisation code flow for the given provider (e.g. `google`,
    `github`). Calls `Accounts.sso_authorize_url/1` to build the provider URL,
    stores CSRF/PKCE `session_params` in the browser session, then redirects the
    browser to the provider's authorisation page.

    On success, the browser receives a 302 to the provider. If the provider is
    unknown or unavailable, the browser is redirected to /users/log-in with a
    flash error. This is a browser-session endpoint; there is no JSON body.
    """,
    parameters: [
      provider: [
        in: :path,
        description: "OAuth provider slug (e.g. \"google\", \"github\")",
        type: :string,
        required: true
      ]
    ],
    responses: [
      "3XX":
        {"Redirect — to the provider's OAuth authorisation URL, or to /users/log-in on error",
         "text/html", %OpenApiSpex.Schema{type: :string, description: "HTML redirect body"}}
    ]
  )

  def request(conn, %{"provider" => provider}) do
    case Accounts.sso_authorize_url(provider) do
      {:ok, %{url: url, session_params: session_params}} ->
        conn
        |> put_session(:oauth_session_params, session_params)
        |> redirect(external: url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That sign-in option isn't available right now.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  operation(:callback,
    summary: "OAuth callback — exchange code, log in (browser redirect flow)",
    tags: ["Auth"],
    description: """
    Handles the provider's redirect back after the user grants permission.
    The provider sends `code` and `state` query parameters; this action:

    1. Reads the stored `oauth_session_params` from the browser session to
       verify CSRF/PKCE state. If missing (expired or direct navigation), the
       browser is redirected to /users/log-in with an error.
    2. Calls `Accounts.sso_sign_in/3` to exchange the code, resolve (or
       create) the PerfectPaper user, and log them in via
       `UserAuth.log_in_user/2`, which sets a session cookie and redirects to
       the dashboard.
    3. On any error (email taken, provider didn't share an email, etc.), the
       browser is redirected to /users/log-in with a descriptive flash message.

    OpenAPI cannot express the cookie/session semantics; the 302 redirect is
    the real contract for every outcome.
    """,
    parameters: [
      provider: [
        in: :path,
        description: "OAuth provider slug (e.g. \"google\", \"github\")",
        type: :string,
        required: true
      ],
      code: [
        in: :query,
        description: "Authorisation code returned by the provider.",
        type: :string,
        required: false
      ],
      state: [
        in: :query,
        description:
          "CSRF state token returned by the provider; verified against `oauth_session_params` stored in the browser session.",
        type: :string,
        required: false
      ]
    ],
    responses: [
      "3XX":
        {"Redirect — sets session cookie on success, or redirects to /users/log-in on failure",
         "text/html", %OpenApiSpex.Schema{type: :string, description: "HTML redirect body"}}
    ]
  )

  def callback(conn, %{"provider" => provider} = params) do
    # Without the state/PKCE params we stored on the request leg, Assent cannot
    # verify CSRF — fail closed with a clean message instead of crashing.
    case get_session(conn, :oauth_session_params) do
      nil ->
        conn
        |> put_flash(:error, error_message(:expired_session))
        |> redirect(to: ~p"/users/log-in")

      session_params ->
        conn = delete_session(conn, :oauth_session_params)

        case Accounts.sso_sign_in(provider, params, session_params) do
          {:ok, user} ->
            UserAuth.log_in_user(conn, user)

          {:error, reason} ->
            conn
            |> put_flash(:error, error_message(reason))
            |> redirect(to: ~p"/users/log-in")
        end
    end
  end

  defp error_message(:email_taken),
    do: "That email already has an account. Log in, then link this provider in Settings."

  defp error_message(:email_required),
    do: "That provider didn't share an email. Try signing up with your email instead."

  defp error_message(:expired_session),
    do: "Your sign-in session expired. Please try again."

  defp error_message(_other), do: "Sign-in failed. Please try again."
end
