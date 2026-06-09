defmodule PerfectPaperWeb.UserSocket do
  @moduledoc """
  WebSocket entry point. Inert scaffold for the future realtime/collaboration
  features (per-paper presence, chat, shared comments). No channels are wired yet,
  and the socket is not mounted in the endpoint — but it is secure by default so
  that wiring a channel later cannot accidentally expose an unauthenticated seam.

  Authentication: the client must pass a signed `token` param. Mint it server-side
  for the current user (e.g. in the mounting layout) with:

      Phoenix.Token.sign(PerfectPaperWeb.Endpoint, "user socket", user.id)

  and verify here on connect. An absent or invalid token is rejected (`:error`),
  so no channel can be joined without a current user.
  """
  use Phoenix.Socket

  # channel "session:*", PerfectPaperWeb.UserChannel  # enabled in a later pass

  @salt "user socket"
  # Match the 14-day session-token window (see Accounts/UserToken).
  @max_age 14 * 24 * 60 * 60

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Phoenix.Token.verify(PerfectPaperWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, user_id} -> {:ok, assign(socket, :current_user_id, user_id)}
      {:error, _reason} -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Per-user socket id so a user's sockets can be disconnected on logout/deactivation.
  @impl true
  def id(%{assigns: %{current_user_id: user_id}}), do: "user_socket:#{user_id}"
  def id(_socket), do: nil
end
