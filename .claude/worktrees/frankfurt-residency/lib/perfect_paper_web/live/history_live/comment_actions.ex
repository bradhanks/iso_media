defmodule PerfectPaperWeb.HistoryLive.CommentActions do
  @moduledoc """
  Shared glue for the dismiss / address / undo comment events, used by both the
  `ReadingRoomLive` and `HistoryLive.Show` surfaces so they stay in lockstep.

  On success it swaps the single changed comment into the socket's session in
  place — no full-session reload — and on failure it flashes a message. Every
  function returns a `{:noreply, socket}` ready to hand back from `handle_event`.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias PerfectPaper.History
  alias PerfectPaper.History.Session

  @doc """
  Applies the result of a `History` comment action (`{:ok, %{comment: c}}` or
  `{:error, _}`): updates that comment in `socket.assigns.session` on success, or
  flashes `error_msg` on failure.
  """
  @spec handle_result(Phoenix.LiveView.Socket.t(), term(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_result(socket, result, error_msg) do
    case result do
      {:ok, %{comment: %{} = updated}} ->
        {:noreply, assign(socket, :session, replace_comment(socket.assigns.session, updated))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  defp replace_comment(%Session{comments: comments} = session, %{id: id} = updated)
       when is_list(comments) do
    %{session | comments: Enum.map(comments, fn c -> if c.id == id, do: updated, else: c end)}
  end

  @doc """
  Maps an undo param to a comment action atom, defaulting to `:dismiss`. Accepts
  both the action form (`"address"`) and the status form (`"addressed"`) the two
  surfaces send.
  """
  @spec undo_type(String.t()) :: History.Comment.action()
  def undo_type(type) when type in ["address", "addressed"], do: :address
  def undo_type(_), do: :dismiss
end
