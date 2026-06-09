defmodule PerfectPaperWeb.Api.HistoryJSON do
  @moduledoc "Renders History sessions and comments as JSON for the REST API."

  alias PerfectPaper.History.{Session, Comment}

  @doc "Renders a list of sessions."
  def index(%{sessions: sessions}), do: %{data: for(s <- sessions, do: session(s))}

  @doc "Renders a single session."
  def show(%{session: session}), do: %{data: session(session)}

  @doc "Renders a single comment."
  def comment(%{comment: comment}), do: %{data: comment_map(comment)}

  defp session(%Session{} = s) do
    %{
      id: s.id,
      title: s.title,
      processing_status: s.processing_status,
      is_public: s.is_public,
      viewed: s.viewed,
      overall_feedback: s.overall_feedback,
      comments: comments(s.comments)
    }
  end

  defp comments(%Ecto.Association.NotLoaded{}), do: []
  defp comments(comments) when is_list(comments), do: for(c <- comments, do: comment_map(c))
  defp comments(_), do: []

  @doc "Renders a single invitation result."
  def invitation(%{invitation: %{user: user, grant: grant}}) do
    %{data: %{user_id: user.id, role: grant.role}}
  end

  defp comment_map(%Comment{} = c) do
    %{
      id: c.id,
      original_text: c.original_text,
      suggestion: c.suggestion,
      explanation: c.explanation,
      category: c.category,
      status: c.status,
      position: c.position,
      author_type: c.author_type,
      author_id: c.author_id,
      body: c.body,
      parent_id: c.parent_id
    }
  end
end
