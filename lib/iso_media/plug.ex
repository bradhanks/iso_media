if Code.ensure_loaded?(Plug.Conn) do
  defmodule ISOMedia.Plug do
    @moduledoc """
    Optional reference `Plug` that serves an ISOBMFF tree with HTTP byte-range semantics,
    backed by `ISOMedia.HTTP`. Compiled only when Plug is available.

    Options (`init/1`):
      * `:resolver` — `(conn -> {:ok, tree | Resource.t()} | {:ok, tree, res_opts} | :not_found)`
      * `:root` — directory; maps `conn.request_path` to a file (read lazily). Use instead of `:resolver`.
      * `:lazy` — read backing files as `FileSlice` (default `true`; the O(range) path)
      * `:cache` — `:none` (default) | `:persistent_term` (cache `Resource` by `{path, mtime, size}`).
        **`:persistent_term` is global, never-evicted, and triggers a global GC on every write.**
        Use it only for a small, stable set of assets (e.g. a handful of VOD files). Do not use it
        with frequently-changing files or an unbounded path space — each distinct `{path, mtime, size}`
        adds a permanent entry and a GC pass.
      * `:chunk_size` — stream chunk size (default 65_536)
      * `:etag`/`:content_type`/`:codecs`/`:last_modified`/`:cache_control`/`:extra_headers` — passed to `resource/2`
    """

    @behaviour Plug
    import Plug.Conn

    alias ISOMedia.HTTP

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      case resolve(conn, opts) do
        :not_found -> conn |> send_resp(404, "Not Found") |> halt()
        {:ok, resource} -> respond(conn, resource, opts)
      end
    end

    defp respond(conn, resource, opts) do
      req = HTTP.from_headers(conn.req_headers, conn.method)
      resp = HTTP.serve(resource, req)

      conn =
        resp.headers
        |> Enum.reduce(conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
        |> put_status(resp.status)

      send_body(conn, resp, opts)
    end

    defp send_body(conn, %{status: status, body: :empty}, _opts),
      do: conn |> send_resp(status, "") |> halt()

    defp send_body(conn, resp, opts) do
      chunk_size = Keyword.get(opts, :chunk_size, 65_536)
      conn = send_chunked(conn, resp.status)

      resp
      |> HTTP.body_stream(chunk_size)
      |> Enum.reduce_while(conn, fn data, c ->
        case chunk(c, data) do
          {:ok, c} -> {:cont, c}
          # Any write failure (client disconnect `:closed`, or an adapter `:timeout`,
          # `:enotconn`, …) stops the stream — the Stream.resource closes its fd in its
          # after_fun, so there is no leak. Matching only `:closed` would crash here.
          {:error, _reason} -> {:halt, c}
        end
      end)
      |> halt()
    end

    # --- resolution ---
    defp resolve(conn, opts) do
      cond do
        fun = opts[:resolver] -> from_resolver(fun.(conn), opts)
        root = opts[:root] -> from_root(conn, root, opts)
        true -> raise ArgumentError, "ISOMedia.Plug requires :resolver or :root"
      end
    end

    defp from_resolver(:not_found, _opts), do: :not_found
    defp from_resolver({:ok, %HTTP.Resource{} = r}, _opts), do: {:ok, r}
    defp from_resolver({:ok, tree, res_opts}, _opts), do: {:ok, HTTP.resource(tree, res_opts)}
    defp from_resolver({:ok, tree}, opts), do: {:ok, HTTP.resource(tree, res_opts(opts))}

    defp from_root(conn, root, opts) do
      root_abs = Path.expand(root)
      target = Path.expand(Path.join(root_abs, "." <> conn.request_path))

      if File.regular?(target) and String.starts_with?(target, root_abs <> "/") do
        cached_resource(target, opts)
      else
        :not_found
      end
    end

    defp cached_resource(path, opts) do
      case Keyword.get(opts, :cache, :none) do
        :none ->
          {:ok, build(path, opts)}

        :persistent_term ->
          %File.Stat{mtime: mtime, size: size} = File.stat!(path)
          key = {__MODULE__, path, mtime, size, res_opts(opts)}

          case :persistent_term.get(key, nil) do
            nil ->
              resource = build(path, opts)
              :persistent_term.put(key, resource)
              {:ok, resource}

            resource ->
              {:ok, resource}
          end
      end
    end

    defp build(path, opts) do
      {:ok, tree} = ISOMedia.read(path, lazy: Keyword.get(opts, :lazy, true))
      opts = Keyword.put_new_lazy(opts, :last_modified, fn -> File.stat!(path).mtime end)
      HTTP.resource(tree, res_opts(opts))
    end

    defp res_opts(opts) do
      Keyword.take(opts, [
        :etag,
        :content_type,
        :codecs,
        :last_modified,
        :cache_control,
        :extra_headers
      ])
    end
  end
end
