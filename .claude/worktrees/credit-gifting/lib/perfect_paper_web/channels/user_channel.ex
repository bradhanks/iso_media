defmodule PerfectPaperWeb.UserChannel do
  @moduledoc """
  Inert scaffold for future realtime/collaboration on a paper. Not wired into the
  socket yet; joins on `"session:<id>"` will broadcast over PubSub once built.
  """
  use Phoenix.Channel

  @impl true
  def join("session:" <> _id, _payload, socket), do: {:ok, socket}
end
