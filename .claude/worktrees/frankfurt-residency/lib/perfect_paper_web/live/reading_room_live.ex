defmodule PerfectPaperWeb.ReadingRoomLive do
  @moduledoc """
  The proofreading reading room — PerfectPaper's flagship surface.

  A three-pane reading room: the manuscript on the left (serif, long-form), the
  AI feedback cards in the middle (overall-feedback panel + per-comment cards a
  writer can address / dismiss / undo), and an optional chat drawer on the right.

  The document + feedback view itself lives in the shared
  `PerfectPaperWeb.ReviewComponents.review_panes/1` component, so this live,
  `PerfectPaper.History`-backed surface and the public static
  `PerfectPaperWeb.DemoLive` render the exact same thing — matching the hero
  animation's "Feedback" step. All mutations route through `PerfectPaper.History`.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Authz, Documents, History}
  alias PerfectPaperWeb.HistoryLive.CommentActions

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    case History.get_session(id, scope(socket)) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Review not found."))
         |> push_navigate(to: ~p"/reviews")}

      session ->
        cond do
          # The review's own workspace is authoritative — canonicalize the URL so
          # a stale/hand-edited workspace never shows it under the wrong space.
          canonical_redirect?(session, params) ->
            {:ok, push_navigate(socket, to: ~p"/w/#{session.workspace_id}/review/#{session.id}")}

          true ->
            mount_session(session, socket)
        end
    end
  end

  defp canonical_redirect?(%{workspace_id: ws_id}, %{"workspace_id" => url_ws})
       when is_binary(ws_id),
       do: ws_id != url_ws

  defp canonical_redirect?(_session, _params), do: false

  defp mount_session(session, socket) do
    document =
      case session.document_id && Documents.get_document(session.document_id) do
        %PerfectPaper.Documents.Document{} = d -> d
        _ -> nil
      end

    canonical = document && Documents.canonical_doc(document)

    if connected?(socket) and session.document_id do
      Phoenix.PubSub.subscribe(PerfectPaper.PubSub, "document:#{session.document_id}")
    end

    {:ok,
     assign(socket,
       page_title: session.title || gettext("Reading room"),
       session: session,
       document: document,
       manuscript_title: manuscript_title(session, document),
       editing_title: false,
       canonical_doc: canonical,
       conversion_status: conversion_status(session, canonical),
       active_anchor: nil,
       show_chat: false,
       show_overall: true,
       sort: :relevance
     )}
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

  def handle_event("undo", %{"id" => comment_id, "action" => action}, socket) do
    CommentActions.handle_result(
      socket,
      History.undo_comment_action(
        session_id(socket),
        comment_id,
        scope(socket),
        CommentActions.undo_type(action)
      ),
      gettext("Could not undo that action.")
    )
  end

  def handle_event("toggle_chat", _params, socket) do
    {:noreply, update(socket, :show_chat, &(!&1))}
  end

  def handle_event("toggle_overall", _params, socket) do
    {:noreply, update(socket, :show_overall, &(!&1))}
  end

  def handle_event("sort_feedback", %{"sort" => sort}, socket) do
    {:noreply, assign(socket, :sort, parse_sort(sort))}
  end

  # Highlight the clicked comment's anchored passage in the manuscript. Clicking
  # the already-active comment (or one with no anchor) clears the highlight.
  def handle_event("select_comment", %{"id" => comment_id}, socket) do
    anchor =
      case Enum.find(socket.assigns.session.comments, &(&1.id == comment_id)) do
        %{anchor_node_id: node_id, anchor_from: from, anchor_to: to}
        when is_binary(node_id) and is_integer(from) and is_integer(to) ->
          %{node_id: node_id, from: from, to: to}

        _ ->
          nil
      end

    anchor = if socket.assigns.active_anchor == anchor, do: nil, else: anchor
    {:noreply, assign(socket, :active_anchor, anchor)}
  end

  # ── Editable manuscript title ──────────────────────────────────────────────
  def handle_event("edit_title", _params, socket),
    do: {:noreply, assign(socket, :editing_title, true)}

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, :editing_title, false)}

  def handle_event("rename", %{"title" => title}, socket) do
    case History.rename_session(socket.assigns.session, scope(socket), title) do
      {:ok, session} ->
        {:noreply,
         assign(socket,
           session: session,
           editing_title: false,
           page_title: session.title,
           manuscript_title: manuscript_title(session, socket.assigns.document)
         )}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:editing_title, false)
         |> put_flash(:error, gettext("Could not rename the manuscript."))}
    end
  end

  @impl true
  def handle_info({:document_converted, _id}, socket) do
    document = Documents.get_document(socket.assigns.session.document_id)

    {:noreply,
     assign(socket,
       document: document,
       canonical_doc: Documents.canonical_doc(document),
       manuscript_title: manuscript_title(socket.assigns.session, document),
       conversion_status: :ready
     )}
  end

  def handle_info({:document_conversion_failed, _id}, socket) do
    {:noreply, assign(socket, conversion_status: :failed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app
      active={:history}
      title={@session.title || gettext("Untitled manuscript")}
      scroll={false}
      flash={@flash}
      current_scope={@current_scope}
      credit_alert={@credit_alert}
      low_credit_dismissed?={@low_credit_dismissed?}
      current_workspace={@current_workspace}
      workspaces={@workspaces}
    >
      <:title_block>
        <form
          :if={@editing_title}
          phx-submit="rename"
          class="mx-auto flex max-w-xl items-center gap-1.5 px-2"
        >
          <input
            name="title"
            value={@manuscript_title}
            maxlength="300"
            autocomplete="off"
            phx-mounted={JS.focus()}
            class="input input-sm input-bordered w-full font-display text-sm font-semibold"
          />
          <button
            type="submit"
            class="btn btn-primary btn-sm btn-square"
            aria-label={gettext("Save title")}
          >
            <.icon name="hero-check" class="size-4" />
          </button>
          <button
            type="button"
            phx-click="cancel_rename"
            class="btn btn-ghost btn-sm btn-square"
            aria-label={gettext("Cancel rename")}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </form>

        <button
          :if={!@editing_title}
          type="button"
          id="manuscript-title"
          phx-hook="FitText"
          phx-click="edit_title"
          title={gettext("Click to rename")}
          class="group mx-auto flex max-w-full items-center justify-center gap-1.5 rounded px-2 py-0.5 hover:bg-base-200"
        >
          <span
            data-fit
            class="line-clamp-2 text-center font-display text-sm font-semibold leading-tight"
          >
            {@manuscript_title}
          </span>
          <.icon
            name="hero-pencil-square"
            class="size-3.5 shrink-0 text-base-content/40 opacity-0 transition-opacity group-hover:opacity-100"
          />
        </button>
      </:title_block>

      <:actions>
        <button
          type="button"
          class="btn btn-ghost btn-sm btn-square"
          aria-label={gettext("Toggle full-screen reading")}
          title={gettext("Full screen")}
          phx-click={JS.toggle_attribute({"data-immersive", "true"}, to: "#app-shell")}
        >
          <svg
            class="size-4"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.7"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M8 3H5a2 2 0 0 0-2 2v3M16 3h3a2 2 0 0 1 2 2v3M8 21H5a2 2 0 0 1-2-2v-3M16 21h3a2 2 0 0 0 2-2v-3" />
          </svg>
        </button>
      </:actions>

      <:actions>
        <div class="dropdown dropdown-end">
          <button type="button" tabindex="0" class="btn btn-ghost btn-sm gap-1.5 font-sans">
            <svg
              class="size-4"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M12 3v12M7 10l5 5 5-5M5 21h14" />
            </svg>
            {gettext("Download")}
          </button>
          <ul
            tabindex="0"
            class="menu dropdown-content z-10 mt-1 w-52 rounded-box border border-base-300 bg-base-100 p-1.5 shadow-md"
          >
            <li>
              <button type="button" onclick="window.print()" class="font-sans text-sm">
                {gettext("Print / save as PDF")}
              </button>
            </li>
            <li>
              <a
                href={~p"/w/#{@current_workspace.id}/review/#{@session.id}/export/docx"}
                class="font-sans text-sm"
              >
                {gettext("Download as DOCX")}
              </a>
            </li>
            <li>
              <a
                href={~p"/w/#{@current_workspace.id}/review/#{@session.id}/export/markdown"}
                class="font-sans text-sm"
              >
                {gettext("Download as Markdown")}
              </a>
            </li>
          </ul>
        </div>

        <button
          type="button"
          class={[
            "btn btn-sm gap-1.5 font-sans",
            @show_chat && "btn-primary",
            !@show_chat && "btn-ghost"
          ]}
          phx-click="toggle_chat"
        >
          <svg
            class="size-4"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.7"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M21 11.5a8.38 8.38 0 01-.9 3.8 8.5 8.5 0 01-7.6 4.7 8.38 8.38 0 01-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 01-.9-3.8 8.5 8.5 0 014.7-7.6 8.38 8.38 0 013.8-.9h.5a8.48 8.48 0 018 8v.5z" />
          </svg>
          {gettext("Chat")}
        </button>
      </:actions>

      <.review_panes
        title={@session.title || gettext("Untitled manuscript")}
        comments={@session.comments}
        overall_feedback={@session.overall_feedback}
        show_overall={@show_overall}
        sort={@sort}
        select_event="select_comment"
      >
        <:document>
          <%= case @conversion_status do %>
            <% :ready -> %>
              <PerfectPaperWeb.DocumentComponents.render_tree
                doc={@canonical_doc}
                active_anchor={@active_anchor}
              />
            <% :converting -> %>
              <p class="font-serif text-base-content/70">{gettext("Converting your manuscript…")}</p>
            <% :failed -> %>
              <p class="font-serif text-error">{gettext("We couldn't process that file.")}</p>
            <% :none -> %>
              <p class="font-serif text-base-content/50">{gettext("No manuscript attached.")}</p>
          <% end %>
        </:document>

        <:chat :if={@show_chat}>
          <.chat_panel title={gettext("Ask about this review")}>
            <:messages>
              <div class="rounded-box bg-base-200/60 px-3.5 py-3">
                <p class="font-serif text-sm leading-relaxed text-base-content/80">
                  {gettext(
                    "Ask anything about this review — what to prioritize, how to address a specific comment, or how the overall assessment was reached."
                  )}
                </p>
              </div>
            </:messages>
          </.chat_panel>
        </:chat>
      </.review_panes>
    </.app>
    """
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp parse_sort("position"), do: :position
  defp parse_sort(_), do: :relevance

  defp conversion_status(%{document_id: nil}, _canonical), do: :none
  defp conversion_status(_session, canonical) when not is_nil(canonical), do: :ready
  defp conversion_status(_session, _canonical), do: :converting

  defp session_id(socket), do: socket.assigns.session.id
  defp scope(socket), do: Authz.load_subject(socket.assigns.current_scope.user)

  # The best title to show: a title the user set explicitly wins; otherwise derive
  # one from the document (a "Title:" line / first real heading → humanized file
  # name). The session title defaults to the file name, so treat that as "unset".
  defp manuscript_title(session, document) do
    default = document && document.filename && Path.rootname(document.filename)
    user_set? = is_binary(session.title) and session.title != "" and session.title != default

    cond do
      user_set? -> session.title
      document -> Documents.display_title(document)
      is_binary(session.title) and session.title != "" -> session.title
      true -> gettext("Untitled manuscript")
    end
  end
end
