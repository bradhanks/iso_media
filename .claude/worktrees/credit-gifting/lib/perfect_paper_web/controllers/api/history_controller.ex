defmodule PerfectPaperWeb.Api.HistoryController do
  @moduledoc """
  REST endpoints for proofreading history. Thin controller — every action calls
  the `PerfectPaper.History` context and renders via `HistoryJSON`. This is the
  end-to-end reference controller for the REST surface.
  """
  use PerfectPaperWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PerfectPaper.History
  alias PerfectPaper.Authz
  alias PerfectPaperWeb.Api.Schemas

  action_fallback PerfectPaperWeb.Api.FallbackController

  operation(:index,
    summary: "List proofreading sessions",
    tags: ["History"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    responses: [
      ok: {"List of sessions", "application/json", Schemas.SessionListResponse}
    ]
  )

  def index(conn, _params) do
    sessions = History.list_sessions(scope(conn))
    render(conn, :index, sessions: sessions)
  end

  operation(:show,
    summary: "Fetch one proofreading session",
    tags: ["History"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Session id", type: :string, required: true]
    ],
    responses: [
      ok: {"The session", "application/json", Schemas.SessionResponse},
      not_found: {"Not found / no access", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    case History.get_session(id, scope(conn)) do
      nil -> {:error, :not_found}
      session -> render(conn, :show, session: session)
    end
  end

  operation(:delete,
    summary: "Delete a proofreading session",
    tags: ["History"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Session id", type: :string, required: true]
    ],
    responses: [
      no_content: "Session deleted",
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Not found / no access", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    s = scope(conn)

    with %History.Session{} = session <- History.get_session(id, s),
         {:ok, _} <- History.delete_session(session, s) do
      send_resp(conn, :no_content, "")
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  operation(:mark_viewed,
    summary: "Mark a session as viewed",
    tags: ["History"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Session id", type: :string, required: true]
    ],
    responses: [
      ok: {"Updated session", "application/json", Schemas.SessionResponse},
      not_found: {"Not found / no access", "application/json", Schemas.Error}
    ]
  )

  def mark_viewed(conn, %{"id" => id}) do
    s = scope(conn)

    with %History.Session{} = session <- History.get_session(id, s),
         {:ok, updated} <- History.mark_viewed(session) do
      render(conn, :show, session: updated)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  operation(:set_visibility,
    summary: "Set public/private visibility of a session",
    tags: ["History"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Session id", type: :string, required: true]
    ],
    request_body:
      {"Visibility flag", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           is_public: %OpenApiSpex.Schema{
             type: :boolean,
             description: "Whether the session should be publicly accessible."
           }
         },
         required: [:is_public]
       }, required: true},
    responses: [
      ok: {"Updated session", "application/json", Schemas.SessionResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Not found / no access", "application/json", Schemas.Error}
    ]
  )

  def set_visibility(conn, %{"id" => id} = params) do
    s = scope(conn)

    with %History.Session{} = session <- History.get_session(id, s),
         {:ok, updated} <- History.set_visibility(session, s, truthy?(params["is_public"])) do
      render(conn, :show, session: updated)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  operation(:dismiss,
    summary: "Dismiss a comment on a session",
    tags: ["History"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      session_id: [in: :path, description: "Session id", type: :string, required: true],
      comment_id: [in: :path, description: "Comment id", type: :string, required: true]
    ],
    responses: [
      ok: {"Updated comment", "application/json", Schemas.CommentResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Not found / no access", "application/json", Schemas.Error}
    ]
  )

  def dismiss(conn, %{"session_id" => sid, "comment_id" => cid}) do
    with {:ok, %{comment: comment}} <-
           History.dismiss_comment(sid, cid, by: scope(conn)) do
      render(conn, :comment, comment: comment)
    end
  end

  operation(:address,
    summary: "Mark a comment as addressed on a session",
    tags: ["History"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      session_id: [in: :path, description: "Session id", type: :string, required: true],
      comment_id: [in: :path, description: "Comment id", type: :string, required: true]
    ],
    responses: [
      ok: {"Updated comment", "application/json", Schemas.CommentResponse},
      forbidden: {"Access denied", "application/json", Schemas.Error},
      not_found: {"Not found / no access", "application/json", Schemas.Error}
    ]
  )

  def address(conn, %{"session_id" => sid, "comment_id" => cid}) do
    with {:ok, %{comment: comment}} <-
           History.address_comment(sid, cid, by: scope(conn)) do
      render(conn, :comment, comment: comment)
    end
  end

  operation(:add_comment,
    summary: "Add a human comment to a session",
    tags: ["History"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Session id", type: :string, required: true]
    ],
    request_body:
      {"Comment body and optional parent", "application/json", Schemas.AddCommentRequest,
       required: true},
    responses: [
      created: {"The new comment", "application/json", Schemas.CommentResponse},
      forbidden: {"Access denied (requires commenter role)", "application/json", Schemas.Error},
      not_found: {"Session not found / no access", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def add_comment(conn, %{"id" => id} = params) do
    with {:ok, comment} <- History.add_comment(id, scope(conn), comment_attrs(params)) do
      conn |> put_status(:created) |> render(:comment, comment: comment)
    end
  end

  operation(:invite,
    summary: "Invite a collaborator to a session",
    tags: ["History"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    parameters: [
      id: [in: :path, description: "Session id", type: :string, required: true]
    ],
    request_body:
      {"Recipient and role", "application/json", Schemas.InvitationRequest, required: true},
    responses: [
      created: {"The new grant", "application/json", Schemas.InvitationResponse},
      forbidden: {"Access denied (requires :share)", "application/json", Schemas.Error},
      not_found: {"Session not found / no access", "application/json", Schemas.Error}
    ]
  )

  def invite(conn, %{"id" => id} = params) do
    s = scope(conn)

    with %History.Session{} = session <- History.get_session(id, s),
         {:ok, result} <-
           History.invite_to_session(session, s, invite_recipient(params), invite_role(params)) do
      conn |> put_status(:created) |> render(:invitation, invitation: result)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  defp scope(conn), do: Authz.load_subject(conn.assigns.current_user)

  # JSON clients may send a real boolean or its string form; anything else
  # (including a missing key) is treated as false rather than truthy.
  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp comment_attrs(params), do: %{body: params["body"], parent_id: params["parent_id"]}

  defp invite_recipient(%{"email" => email}) when is_binary(email), do: email
  defp invite_recipient(%{"user_id" => uid}) when is_binary(uid), do: %{id: uid}
  defp invite_recipient(_), do: nil

  # Whitelist mapping — no String.to_existing_atom/1 to avoid atom-table exhaustion
  # on arbitrary user input; unknown strings fall through to :commenter.
  defp invite_role(%{"role" => r}) do
    case r do
      "viewer" -> :viewer
      "commenter" -> :commenter
      "editor" -> :editor
      _ -> :commenter
    end
  end

  defp invite_role(_), do: :commenter
end
