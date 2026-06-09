defmodule PerfectPaperWeb.ClientMetadata do
  @moduledoc """
  Extracts request metadata (currently the client IP) from a connected
  LiveView socket. Returns `nil` when metadata is unavailable (e.g. the static
  render before the socket connects), so callers fall back to a shared bucket:

      ip = ClientMetadata.client_ip(socket) || "unknown"
  """

  @doc "Client IP for a connected socket, or `nil` if unavailable."
  @spec client_ip(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def client_ip(socket) do
    socket
    |> Phoenix.LiveView.get_connect_info(:x_headers)
    |> case do
      nil -> %{}
      headers -> %{x_headers: headers}
    end
    |> Map.put(:peer_data, Phoenix.LiveView.get_connect_info(socket, :peer_data))
    |> ip_from_connect_info()
  end

  @doc """
  Pure resolution of an IP string from connect-info fields. Prefers the first
  hop of `x-forwarded-for`, then the `peer_data` address, else `nil`.
  """
  @spec ip_from_connect_info(map()) :: String.t() | nil
  def ip_from_connect_info(info) when is_map(info) do
    forwarded_ip(info[:x_headers]) || peer_ip(info[:peer_data])
  end

  defp forwarded_ip(headers) when is_list(headers) do
    case List.keyfind(headers, "x-forwarded-for", 0) do
      {_k, value} ->
        value |> String.split(",") |> List.first() |> String.trim() |> presence()

      _ ->
        nil
    end
  end

  defp forwarded_ip(_), do: nil

  defp peer_ip(%{address: address}) when is_tuple(address) do
    address |> :inet.ntoa() |> to_string() |> presence()
  end

  defp peer_ip(_), do: nil

  defp presence(""), do: nil
  defp presence(string), do: string
end
