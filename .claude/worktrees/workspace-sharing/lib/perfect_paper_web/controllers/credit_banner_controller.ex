defmodule PerfectPaperWeb.CreditBannerController do
  @moduledoc "Sets a per-session cookie dismissing the low-credit banner."
  use PerfectPaperWeb, :controller

  @cookie "pp_low_credit_dismissed"

  @spec dismiss(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dismiss(conn, _params) do
    conn
    |> put_resp_cookie(@cookie, "1", sign: true, max_age: 60 * 60 * 24, same_site: "Lax")
    |> send_resp(:no_content, "")
  end
end
