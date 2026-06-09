defmodule PerfectPaperWeb.HistoryLive.Index do
  @moduledoc "Lists the signed-in writer's proofreading sessions."
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Authz, History}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Reviews"),
       sessions:
         History.list_session_summaries(scope(socket),
           workspace_id: socket.assigns.current_workspace.id
         )
     )}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    s = scope(socket)

    with %History.Session{} = session <- History.get_session(id, s),
         {:ok, _} <- History.delete_session(session, s) do
      {:noreply,
       socket
       |> assign(:sessions, Enum.reject(socket.assigns.sessions, &(&1.id == id)))
       |> put_flash(:info, gettext("Review deleted."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not delete that review."))}
    end
  end

  defp scope(socket), do: Authz.load_subject(socket.assigns.current_scope.user)
end
