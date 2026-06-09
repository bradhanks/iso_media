defmodule PerfectPaperWeb.Plugs.ScimAuth do
  @moduledoc """
  Authenticates a SCIM request via its per-org bearer token. On success assigns
  `:scim_org_id`; on failure halts with a 401 SCIM Error envelope. This plug
  authorizes ONLY `/scim/v2` — a SCIM token cannot reach the regular API.
  """
  import Plug.Conn
  alias PerfectPaper.Scim

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, org_id} <- Scim.verify_token(String.trim(token)) do
      assign(conn, :scim_org_id, org_id)
    else
      _ -> halt_unauthorized(conn)
    end
  end

  defp halt_unauthorized(conn) do
    body =
      Jason.encode!(%{
        "schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"],
        "status" => "401",
        "detail" => "Invalid or missing SCIM bearer token"
      })

    conn
    |> put_resp_content_type("application/scim+json")
    |> send_resp(401, body)
    |> halt()
  end
end
