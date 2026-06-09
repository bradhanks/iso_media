defmodule PerfectPaperWeb.Plugs.UnicodeSanitizer do
  @moduledoc """
  Detects and strips invisible Unicode injection payloads from request
  parameters before they reach controllers, LiveView mounts, or any code that
  forwards user text to the language model.

  PerfectPaper proofreads user-submitted manuscripts with an LLM, so hidden
  instructions encoded in zero-width or Unicode-Tags characters are a real
  prompt-injection vector. This plug runs at the request boundary as the first
  line of defense; `PerfectPaper.Security.UnicodeSanitizer.validate_no_hidden_unicode/2`
  is the changeset-level companion for text that arrives over the LiveView socket.

  ## Modes

  - `:strip` (default) — sanitize params and continue, logging detections at
    `:warning`. Hidden characters are silently removed; appropriate for
    production so detection behavior isn't leaked to attackers.
  - `:block` — halt with HTTP 422 and a generic validation error. Use when you
    want to measure injection attempts or enforce strict rejection.

  ## Router usage

      plug PerfectPaperWeb.Plugs.UnicodeSanitizer            # strip (default)
      plug PerfectPaperWeb.Plugs.UnicodeSanitizer, mode: :block

  Only `body_params` and `query_params` are scanned. URL path params (slugs,
  ids) are short structured values that cannot carry encoded payloads and are
  left untouched. `Plug.Upload` structs pass through unchanged.
  """

  @behaviour Plug

  require Logger

  import Plug.Conn

  alias PerfectPaper.Security.UnicodeSanitizer

  @impl Plug
  def init(opts), do: %{mode: Keyword.get(opts, :mode, :strip)}

  @impl Plug
  def call(conn, %{mode: mode}) do
    body_params = safe_params(conn.body_params)
    query_params = safe_params(conn.query_params)

    findings =
      UnicodeSanitizer.scan_params(body_params) ++ UnicodeSanitizer.scan_params(query_params)

    if findings == [] do
      conn
    else
      log_detection(conn, findings)

      case mode do
        :block -> block(conn)
        :strip -> strip(conn, body_params, query_params)
      end
    end
  end

  # Private

  # Guard against Plug.Conn.Unfetched (params not parsed yet) or nil.
  defp safe_params(%Plug.Conn.Unfetched{}), do: %{}
  defp safe_params(nil), do: %{}
  defp safe_params(params) when is_map(params), do: params

  defp strip(conn, body_params, query_params) do
    clean_body = UnicodeSanitizer.sanitize_params(body_params)
    clean_query = UnicodeSanitizer.sanitize_params(query_params)

    # Rebuild merged params: query < body < path (path params are not sanitized).
    clean_merged =
      clean_query
      |> Map.merge(clean_body)
      |> Map.merge(safe_params(conn.path_params))

    %{conn | body_params: clean_body, query_params: clean_query, params: clean_merged}
  end

  defp block(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(422, Jason.encode!(%{error: "Invalid input"}))
    |> halt()
  end

  defp log_detection(conn, findings) do
    fields =
      findings
      |> Enum.map(fn {path, cats} ->
        "#{Enum.map_join(path, ".", &to_string/1)}: #{inspect(cats)}"
      end)
      |> Enum.join(", ")

    Logger.warning(
      "[UnicodeSanitizer] Invisible Unicode injection detected and sanitized",
      ip: client_ip(conn),
      path: conn.request_path,
      method: conn.method,
      fields: fields
    )
  end

  # Rightmost-hop-agnostic client IP: first entry of X-Forwarded-For, else the
  # peer address. Kept local to the plug so it works on a Plug.Conn (the
  # socket-based PerfectPaperWeb.ClientMetadata is for LiveView).
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] ->
        value |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
