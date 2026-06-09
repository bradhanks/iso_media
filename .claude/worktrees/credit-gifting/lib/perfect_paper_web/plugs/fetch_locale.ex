defmodule PerfectPaperWeb.Plugs.FetchLocale do
  @moduledoc """
  Resolves the request locale (logged-in user → `pp_locale` cookie →
  `Accept-Language` → default), sets it as the Gettext locale for the render, and
  stashes it in assigns + the session (so the LiveView `:load_locale` on_mount can
  read it without re-parsing).
  """
  import Plug.Conn

  alias PerfectPaper.Localization

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    locale =
      Localization.resolve(
        user: current_user(conn),
        cookie: conn.cookies["pp_locale"],
        accept_language: conn |> get_req_header("accept-language") |> List.first()
      )

    Gettext.put_locale(PerfectPaperWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> put_session(:locale, locale)
  end

  defp current_user(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{} = user} -> user
      _ -> nil
    end
  end
end
