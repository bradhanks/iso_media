defmodule PerfectPaperWeb.CookieConsentController do
  @moduledoc """
  Records a visitor's cookie-consent decision and serves the standalone
  preferences page. The effective state for rendering is resolved upstream by
  `PerfectPaperWeb.Plugs.FetchCookieConsent`.
  """

  use PerfectPaperWeb, :controller

  alias PerfectPaper.Compliance

  @doc "Standalone cookie preferences page — lets consent be changed any time."
  def show(conn, _params) do
    render(conn, :show,
      consent: conn.assigns.cookie_consent,
      page_title: "Cookie settings"
    )
  end

  @doc "Records the decision in a signed cookie and returns the visitor to where they were."
  def update(conn, params) do
    decision = decision_from_params(params)

    case Compliance.build_consent(decision, region: country(conn)) do
      {:ok, consent} ->
        conn
        |> put_consent_cookie(consent)
        |> redirect(to: return_to(params))

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "We couldn't save your cookie choices. Please try again.")
        |> redirect(to: return_to(params))
    end
  end

  defp decision_from_params(%{"action" => "accept_all"}), do: :accept_all
  defp decision_from_params(%{"action" => "reject_all"}), do: :reject_all
  defp decision_from_params(%{"consent" => consent}) when is_map(consent), do: consent
  # No recognizable input — fail closed (deny non-essential).
  defp decision_from_params(_), do: :reject_all

  defp put_consent_cookie(conn, consent) do
    put_resp_cookie(conn, Compliance.cookie_name(), Compliance.encode_cookie(consent),
      sign: true,
      max_age: Compliance.cookie_max_age(),
      same_site: "Lax"
    )
  end

  # Only same-origin paths are honored, to avoid an open redirect.
  defp return_to(%{"return_to" => path}) when is_binary(path) do
    if local_path?(path), do: path, else: ~p"/"
  end

  defp return_to(_), do: ~p"/"

  # Reject protocol-relative ("//host") and absolute ("https://…") URLs.
  defp local_path?("//" <> _), do: false
  defp local_path?("/" <> _), do: true
  defp local_path?(_), do: false

  defp country(conn), do: Compliance.country_from_conn(conn)
end
