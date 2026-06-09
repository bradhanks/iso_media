defmodule PerfectPaperWeb.HistoryLive.Show do
  @moduledoc "Shows one session's feedback and lets the writer act on comments."
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Accounts, Authz, History}
  alias PerfectPaperWeb.HistoryLive.CommentActions

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    sc = scope(socket)

    case History.get_session(id, sc) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Session not found."))
         |> push_navigate(to: ~p"/history")}

      session ->
        can_comment? = Authz.permit?(sc, :comment, session) == :ok
        can_share? = Authz.permit?(sc, :share, session) == :ok

        grants =
          if can_share? do
            case Authz.list_grants(sc, {:session, session.id}) do
              {:ok, gs} -> gs
              {:error, _} -> []
            end
          else
            []
          end

        {:ok,
         socket
         |> assign(
           page_title: session.title || gettext("Review"),
           session: mark_viewed(session),
           can_comment?: can_comment?,
           can_share?: can_share?,
           grants: grants,
           reply_to: nil
         )}
    end
  end

  @impl true
  def handle_event("dismiss", %{"id" => comment_id}, socket) do
    CommentActions.handle_result(
      socket,
      History.dismiss_comment(session_id(socket), comment_id, by: scope(socket)),
      gettext("Could not update that comment.")
    )
  end

  def handle_event("address", %{"id" => comment_id}, socket) do
    CommentActions.handle_result(
      socket,
      History.address_comment(session_id(socket), comment_id, by: scope(socket)),
      gettext("Could not update that comment.")
    )
  end

  def handle_event("undo", %{"id" => comment_id, "type" => type}, socket) do
    CommentActions.handle_result(
      socket,
      History.undo_comment_action(
        session_id(socket),
        comment_id,
        scope(socket),
        CommentActions.undo_type(type)
      ),
      gettext("Could not undo that action.")
    )
  end

  def handle_event("toggle_visibility", _params, socket) do
    case History.set_visibility(
           socket.assigns.session,
           scope(socket),
           !socket.assigns.session.is_public
         ) do
      {:ok, session} -> {:noreply, assign(socket, :session, session)}
      {:error, _} -> {:noreply, put_flash(socket, :error, gettext("Could not update sharing."))}
    end
  end

  def handle_event("show_reply_form", %{"parent_id" => parent_id}, socket) do
    {:noreply, assign(socket, :reply_to, parent_id)}
  end

  def handle_event("hide_reply_form", _params, socket) do
    {:noreply, assign(socket, :reply_to, nil)}
  end

  def handle_event("add_comment", %{"comment" => params}, socket) do
    body = Map.get(params, "body", "") |> String.trim()
    parent_id = Map.get(params, "parent_id") |> blank_to_nil()

    if body == "" do
      {:noreply, put_flash(socket, :error, gettext("Comment body cannot be empty."))}
    else
      case History.add_comment(session_id(socket), scope(socket), %{
             body: body,
             parent_id: parent_id
           }) do
        {:ok, _comment} ->
          sc = scope(socket)
          session = History.get_session(session_id(socket), sc)

          {:noreply,
           socket
           |> assign(session: session, reply_to: nil)
           |> put_flash(:info, gettext("Comment added."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not add comment."))}
      end
    end
  end

  def handle_event("invite", %{"invite" => %{"email" => email, "role" => role}}, socket) do
    role_atom =
      case role do
        "viewer" -> :viewer
        "commenter" -> :commenter
        "editor" -> :editor
        _ -> :commenter
      end

    case History.invite_to_session(socket.assigns.session, scope(socket), email, role_atom) do
      {:ok, _result} ->
        sc = scope(socket)

        grants =
          case Authz.list_grants(sc, {:session, session_id(socket)}) do
            {:ok, gs} -> gs
            {:error, _} -> socket.assigns.grants
          end

        {:noreply,
         socket
         |> assign(grants: grants)
         |> put_flash(:info, gettext("Invitation sent to %{email}.", email: email))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not send invitation."))}
    end
  end

  def handle_event("revoke", %{"user_id" => user_id}, socket) do
    case Authz.revoke_access(scope(socket), {:session, session_id(socket)}, {:user, user_id}) do
      :ok ->
        sc = scope(socket)

        grants =
          case Authz.list_grants(sc, {:session, session_id(socket)}) do
            {:ok, gs} -> gs
            {:error, _} -> socket.assigns.grants
          end

        {:noreply,
         socket
         |> assign(grants: grants)
         |> put_flash(:info, gettext("Access revoked."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not revoke access."))}
    end
  end

  @doc "Loads the display name for a comment's author, or nil for AI comments."
  @spec author_label(map()) :: String.t() | nil
  def author_label(%{author_type: :ai}), do: nil
  def author_label(%{author_id: nil}), do: gettext("Collaborator")

  def author_label(%{author_id: author_id}) do
    case Accounts.get_user(author_id) do
      %{email: email} when is_binary(email) -> email |> String.split("@") |> hd()
      _ -> gettext("Collaborator")
    end
  end

  @doc "Groups comments into {top_level, replies_by_parent_id}."
  @spec group_comments([map()]) :: {[map()], map()}
  def group_comments(comments) do
    {top, replies} = Enum.split_with(comments, &is_nil(&1.parent_id))
    reply_map = Enum.group_by(replies, & &1.parent_id)
    {top, reply_map}
  end

  # Clear the unread indicator when the owner opens the review. Best-effort:
  # keep the loaded session on failure rather than breaking the page.
  defp mark_viewed(%{viewed: true} = session), do: session

  defp mark_viewed(session) do
    case History.mark_viewed(session) do
      {:ok, viewed} -> viewed
      {:error, _} -> session
    end
  end

  defp session_id(socket), do: socket.assigns.session.id
  defp scope(socket), do: Authz.load_subject(socket.assigns.current_scope.user)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
