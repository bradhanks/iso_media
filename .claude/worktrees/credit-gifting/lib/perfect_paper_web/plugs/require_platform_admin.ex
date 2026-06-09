defmodule PerfectPaperWeb.Plugs.RequirePlatformAdmin do
  @moduledoc """
  Halts a REST request unless the authenticated caller (`:current_user`, set by
  `ApiAuth`) is a platform admin — i.e. their email is in the `admin_emails`
  allowlist (the same gate as `/admin`). Used for internal, sales-arranged
  billing mutations (contract create/activate, invoice mark-paid/void).
  """
  import Plug.Conn
  alias PerfectPaperWeb.UserAuth

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    user = conn.assigns[:current_user]

    if user && String.downcase(user.email) in UserAuth.admin_emails() do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{detail: "Forbidden"}))
      |> halt()
    end
  end
end
