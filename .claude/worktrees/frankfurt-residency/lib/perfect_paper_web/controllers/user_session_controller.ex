defmodule PerfectPaperWeb.UserSessionController do
  use PerfectPaperWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PerfectPaper.Accounts
  alias PerfectPaperWeb.UserAuth

  operation(:create,
    summary: "Log in with email + password (browser/session flow)",
    tags: ["Auth"],
    description: """
    Authenticates the user by email and password (or a magic-link token in the
    `user[token]` field). This is a browser session endpoint: on success,
    `UserAuth.log_in_user/2` sets a signed session cookie and redirects the
    browser to the dashboard or the page requested before login. On failure,
    the browser is redirected back to the login page with a flash error.

    OpenAPI cannot fully express cookie-based session semantics; the 302
    response is the real contract for both success and failure.
    """,
    request_body:
      {"Email/password credentials (wrapped in a `user` key)", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           user: %OpenApiSpex.Schema{
             type: :object,
             description:
               "Credential payload. Send `email` + `password` for password login, or `token` for magic-link login.",
             properties: %{
               email: %OpenApiSpex.Schema{
                 type: :string,
                 format: :email,
                 description: "Registered email address (password login)."
               },
               password: %OpenApiSpex.Schema{
                 type: :string,
                 format: :password,
                 description: "User password (password login)."
               },
               token: %OpenApiSpex.Schema{
                 type: :string,
                 description: "Magic-link token (magic-link login; omit email/password)."
               }
             }
           }
         },
         required: [:user]
       }, required: true},
    responses: [
      "3XX":
        {"Redirect — sets session cookie on success, or redirects to /users/log-in on failure",
         "text/html", %OpenApiSpex.Schema{type: :string, description: "HTML redirect body"}}
    ]
  )

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn =
          case safe_redirect(Map.get(user_params, "redirect_to")) do
            nil -> conn
            path -> put_session(conn, :user_return_to, path)
          end

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # Returns the path unchanged if it is a safe internal path: must start with "/"
  # (but not "//") and must not contain a scheme (no ":"). Returns nil for anything
  # else so the caller falls back to the default post-login path, preventing open
  # redirects.
  defp safe_redirect(nil), do: nil

  defp safe_redirect(path) when is_binary(path) do
    if String.match?(path, ~r/\A\/[^\/]/) and
         not String.contains?(path, ":") and
         not String.contains?(path, "\\") do
      path
    else
      nil
    end
  end

  operation(:delete,
    summary: "Log out (browser/session flow)",
    tags: ["Auth"],
    description: """
    Clears the session cookie and logs the user out via `UserAuth.log_out_user/1`.
    Always responds with a 302 redirect to the home/login page. This is a
    browser-session endpoint; there is no JSON response body.
    """,
    responses: [
      "3XX":
        {"Redirect — session cleared, browser redirected to /users/log-in", "text/html",
         %OpenApiSpex.Schema{type: :string, description: "HTML redirect body"}}
    ]
  )

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end

  operation(:update_password,
    summary: "Update password for the authenticated user (browser/session flow)",
    tags: ["Auth"],
    description: """
    Changes the authenticated user's password. Requires sudo mode (the user must
    have authenticated recently). On success, all existing sessions are
    disconnected and the user is immediately re-logged in, setting a new session
    cookie and redirecting to /users/settings. This is a browser-session endpoint;
    the response is always a 302 redirect.
    """,
    request_body:
      {"New password payload (wrapped in a `user` key)", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           user: %OpenApiSpex.Schema{
             type: :object,
             description: "Password update payload.",
             properties: %{
               password: %OpenApiSpex.Schema{
                 type: :string,
                 format: :password,
                 description: "The new password."
               },
               password_confirmation: %OpenApiSpex.Schema{
                 type: :string,
                 format: :password,
                 description: "Confirmation — must match `password`."
               },
               current_password: %OpenApiSpex.Schema{
                 type: :string,
                 format: :password,
                 description: "The user's current password for verification."
               }
             },
             required: [:password, :password_confirmation, :current_password]
           }
         },
         required: [:user]
       }, required: true},
    responses: [
      "3XX":
        {"Redirect — session refreshed, browser redirected to /users/settings", "text/html",
         %OpenApiSpex.Schema{type: :string, description: "HTML redirect body"}}
    ]
  )

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end
end
