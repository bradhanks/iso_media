defmodule PerfectPaperWeb.Plugs.FetchLowCreditDismiss do
  @moduledoc """
  Reads the signed low-credit-dismiss cookie into the session so the authenticated
  LiveView `on_mount` (`:assign_credit_alert`) can hide the banner without a
  request round-trip.
  """
  import Plug.Conn

  @behaviour Plug
  @cookie "pp_low_credit_dismissed"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn, signed: [@cookie])
    put_session(conn, :low_credit_dismissed, conn.cookies[@cookie] == "1")
  end
end
