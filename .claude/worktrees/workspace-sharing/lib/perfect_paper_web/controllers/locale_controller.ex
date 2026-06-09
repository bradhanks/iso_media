defmodule PerfectPaperWeb.LocaleController do
  @moduledoc """
  Records a visitor's language choice: sets the `pp_locale` cookie and, when
  logged in, persists `users.locale`. Returns the visitor to where they were.
  """
  use PerfectPaperWeb, :controller

  alias PerfectPaper.{Accounts, Localization}

  @one_year 60 * 60 * 24 * 365

  def update(conn, params) do
    locale = params["locale"]

    conn =
      if Localization.known?(locale) do
        conn
        |> put_resp_cookie("pp_locale", locale, max_age: @one_year, same_site: "Lax")
        |> maybe_persist(locale)
      else
        conn
      end

    redirect(conn, to: return_to(params, conn))
  end

  defp maybe_persist(conn, locale) do
    case conn.assigns[:current_scope] do
      %{user: %Accounts.User{} = user} ->
        Accounts.update_user_locale(user, locale)
        conn

      _ ->
        conn
    end
  end

  defp return_to(%{"return_to" => path}, _conn) when is_binary(path) do
    if local_path?(path), do: path, else: ~p"/"
  end

  defp return_to(_params, conn) do
    case get_req_header(conn, "referer") do
      [referer | _] -> referer_path(referer)
      _ -> ~p"/"
    end
  end

  # Only same-origin paths; reject protocol-relative and absolute URLs.
  defp local_path?("//" <> _), do: false
  defp local_path?("/" <> _), do: true
  defp local_path?(_), do: false

  defp referer_path(referer) do
    case URI.parse(referer) do
      %URI{path: "/" <> _ = path} -> path
      _ -> ~p"/"
    end
  end
end
