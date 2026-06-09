defmodule PerfectPaperWeb.WorkspaceRedirectController do
  @moduledoc """
  Forwards bare workspace-scoped paths (`/reviews`, `/new`) to the user's
  last-used (or Personal) workspace under `/w/:workspace_id/…`. A plain
  controller — no LiveView connection overhead — so old bookmarks and the
  post-login landing keep working.
  """
  use PerfectPaperWeb, :controller

  alias PerfectPaper.Workspaces

  @spec reviews(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reviews(conn, _params), do: redirect(conn, to: ~p"/w/#{ws(conn).id}/reviews")

  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, _params), do: redirect(conn, to: ~p"/w/#{ws(conn).id}/new")

  defp ws(conn) do
    user = conn.assigns.current_scope.user

    with id when is_binary(id) <- user.active_workspace_id,
         {:ok, workspace} <- Workspaces.get_workspace(id, user) do
      workspace
    else
      _ -> Workspaces.personal_workspace(user)
    end
  end
end
