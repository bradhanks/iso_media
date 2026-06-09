defmodule PerfectPaperWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Custom `Plug.Parsers` body reader that stashes the **raw** request body in
  `conn.private[:raw_body]` as it streams, so webhook controllers can verify a
  provider signature over the exact bytes (a parsed body breaks the HMAC).

  Wired in the endpoint's `Plug.Parsers` via `body_reader:`. The raw body is only
  needed on the webhook path, but caching every request's body is the standard
  Plug pattern and the cost is negligible.
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, stash(conn, body)}
      {:more, body, conn} -> {:more, body, stash(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stash(conn, body), do: update_in(conn.private[:raw_body], &((&1 || "") <> body))
end
