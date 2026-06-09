defmodule PerfectPaperWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates a REST request via `Authorization: Bearer <token>` (an API key
  or a session token). On success assigns `:current_user`; otherwise halts with a
  401 in the FastAPI-style `{"detail": ...}` envelope.
  """
  import Plug.Conn

  alias PerfectPaperWeb.Tokens

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    with ["Bearer " <> value] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Tokens.user_for_bearer(String.trim(value)) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{detail: "Not authenticated"}))
        |> halt()
    end
  end
end
