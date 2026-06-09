defmodule PerfectPaperWeb.UserAuth do
  use PerfectPaperWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias PerfectPaper.Accounts
  alias PerfectPaper.Accounts.Scope
  alias PerfectPaper.Workspaces

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_perfect_paper_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      PerfectPaperWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token),
         # A deactivated (directory-deprovisioned) user cannot hold a session.
         true <- is_nil(user.deactivated_at) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      _ -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    # TODO(mfa): if Accounts.mfa_required_for?(user) and this session is not yet
    # MFA-verified, redirect to the MFA challenge before establishing the full
    # session (set a partial/"mfa_pending" session instead). See Spec 6.
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _user) do
    delete_csrf_token()
    locale = get_session(conn, :locale)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> then(fn conn -> if locale, do: put_session(conn, :locale, locale), else: conn end)
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      PerfectPaperWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

    * `:load_locale` - Resolves and applies the effective locale. Priority:
      user's `users.locale` → session `"locale"` (stashed by `FetchLocale`)
      → `Localization.default_locale/0`. Calls `Gettext.put_locale/2` and
      assigns `:locale`. Must run AFTER any scope-loading hook.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule PerfectPaperWeb.PageLive do
        use PerfectPaperWeb, :live_view

        on_mount {PerfectPaperWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{PerfectPaperWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.user, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must re-authenticate to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    if user && String.downcase(user.email) in admin_emails() do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You do not have access to that page.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  def on_mount(:require_mfa, _params, _session, socket) do
    # TODO(mfa): halt/redirect an authenticated-but-not-MFA-verified session when
    # Accounts.mfa_required_for?(current_user). No-op until the MFA flow ships.
    {:cont, socket}
  end

  def on_mount(:load_locale, _params, session, socket) do
    locale =
      cond do
        match?(%{user: %{}}, socket.assigns[:current_scope]) and
            PerfectPaper.Localization.known?(socket.assigns.current_scope.user.locale) ->
          socket.assigns.current_scope.user.locale

        is_binary(session["locale"]) and PerfectPaper.Localization.known?(session["locale"]) ->
          session["locale"]

        true ->
          PerfectPaper.Localization.default_locale()
      end

    Gettext.put_locale(PerfectPaperWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  # on_mount(:assign_workspace, …) assigns @current_workspace and @workspaces on
  # every authenticated page. Scoped routes (/w/:workspace_id/…) resolve the URL
  # workspace (redirecting if it isn't the user's); global routes resolve the
  # user's last-used/Personal default so the sidebar switcher + nav links always
  # have their assigns.
  def on_mount(:assign_workspace, params, _session, socket) do
    user = socket.assigns.current_scope.user
    workspaces = Workspaces.list_workspaces(user)

    case params do
      %{"workspace_id" => id} ->
        case Workspaces.get_workspace(id, user) do
          {:ok, ws} ->
            _ = Workspaces.set_active(user, ws.id)

            {:cont,
             socket
             |> Phoenix.Component.assign(:current_workspace, ws)
             |> Phoenix.Component.assign(:workspaces, workspaces)}

          {:error, :not_found} ->
            default = default_workspace(user)

            {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/w/#{default.id}/reviews")}
        end

      _ ->
        {:cont,
         socket
         |> Phoenix.Component.assign(:current_workspace, default_workspace(user))
         |> Phoenix.Component.assign(:workspaces, workspaces)}
    end
  end

  # on_mount(:assign_credit_alert, …) computes the inputs for the stateless
  # low-credit banner once per authenticated mount: the user's personal balance,
  # their effective threshold, whether they're annual, and their pricing band
  # (from the session, set by FetchPricingCountry). Also reads the per-session
  # dismiss flag (set by FetchLowCreditDismiss). Runs after :require_authenticated
  # so current_scope.user is present. Cheap: one indexed SUM over credit_events.
  def on_mount(:assign_credit_alert, _params, session, socket) do
    %{id: user_id} = user = socket.assigns.current_scope.user
    sub = PerfectPaper.Billing.get_subscription_for_user(user_id)

    credit_alert = %{
      balance: PerfectPaper.Credits.balance(user_id),
      threshold: PerfectPaper.Credits.effective_low_credit_threshold(user, sub),
      annual?: !!(sub && sub.billing_period == :annual),
      band: band_from_session(session)
    }

    {:cont,
     socket
     |> Phoenix.Component.assign(:credit_alert, credit_alert)
     |> Phoenix.Component.assign(:low_credit_dismissed?, session["low_credit_dismissed"] == true)}
  end

  defp default_workspace(user) do
    with id when is_binary(id) <- user.active_workspace_id,
         {:ok, ws} <- Workspaces.get_workspace(id, user) do
      ws
    else
      _ -> Workspaces.personal_workspace(user)
    end
  end

  defp band_from_session(session) do
    case session["pricing_band"] do
      b when b in ["a", "b", "c", "d"] -> String.to_existing_atom(b)
      _ -> :a
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc "Returns the path to redirect to after log in (bounces to the user's workspace)."
  def signed_in_path(_), do: ~p"/new"

  @doc "Returns the configured admin email allowlist, downcased."
  @spec admin_emails() :: [String.t()]
  def admin_emails do
    :perfect_paper
    |> Application.get_env(:admin_emails, [])
    |> Enum.map(&String.downcase/1)
  end

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
