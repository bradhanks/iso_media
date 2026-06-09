defmodule PerfectPaperWeb.UserSocketTest do
  use ExUnit.Case, async: true

  alias PerfectPaperWeb.{Endpoint, UserSocket}

  defp blank_socket, do: %Phoenix.Socket{}

  test "connects with a valid signed token and scopes the socket id to the user" do
    token = Phoenix.Token.sign(Endpoint, "user socket", "user-123")

    assert {:ok, socket} = UserSocket.connect(%{"token" => token}, blank_socket(), %{})
    assert socket.assigns.current_user_id == "user-123"
    assert UserSocket.id(socket) == "user_socket:user-123"
  end

  test "rejects a missing token (no unauthenticated connection)" do
    assert :error = UserSocket.connect(%{}, blank_socket(), %{})
  end

  test "rejects an invalid/garbage token" do
    assert :error = UserSocket.connect(%{"token" => "not-a-real-token"}, blank_socket(), %{})
  end

  test "rejects a token signed with the wrong salt" do
    wrong = Phoenix.Token.sign(Endpoint, "some other salt", "user-123")
    assert :error = UserSocket.connect(%{"token" => wrong}, blank_socket(), %{})
  end
end
