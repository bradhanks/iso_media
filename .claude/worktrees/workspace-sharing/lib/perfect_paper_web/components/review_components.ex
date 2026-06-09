defmodule PerfectPaperWeb.ReviewComponents do
  @moduledoc """
  The review reading-room view — the document on the left, the AI feedback
  (overall summary + per-comment cards) on the right. This is the exact surface
  the marketing hero animation previews at its "Feedback" step.

  `review_panes/1` is the single source of truth for that view: both the live
  `PerfectPaperWeb.ReadingRoomLive` (backed by `PerfectPaper.History`) and the
  public static `PerfectPaperWeb.DemoLive` render it, so the real app matches the
  animation/demo exactly.

  It is data-shape agnostic: pass `comments` as a list of maps/structs carrying
  `:id`, `:status` (`:open | :addressed | :dismissed`), and the optional
  `:original_text`, `:suggestion`, `:explanation`, `:category` fields — i.e. the
  `PerfectPaper.History.Comment` shape, or a plain map for static demos.

  Two interactions are opt-in (default off, so existing callers are unchanged):

    * `archivable` — adds an Archive action per comment and collapses archived
      comments into an "Archived" section (reads/sets an `:archived` field).
    * `threads` — renders a comment chain under each card (reads a `:replies`
      list of `%{author, role, text}`) plus a reply form, so people or the
      chatbot can add criticism.

  The action buttons emit `"address"` / `"dismiss"` / `"undo"` (and, when opted
  in, `"archive"` / `"unarchive"` / `"reply"` / `"ask_bot"`, plus the overall
  panel's `"toggle_overall"`), which the hosting LiveView handles.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.AppShell,
    only: [workspace: 1, doc_pane_header: 1, feedback_pane_header: 1]

  import PerfectPaperWeb.DesignSystem, only: [badge: 1]

  @doc """
  Renders the document + feedback panes for a review.

  ## Examples

      <.review_panes title={@session.title} comments={@session.comments}
        overall_feedback={@session.overall_feedback} show_overall={@show_overall} />
  """
  attr :title, :string, default: "Untitled manuscript"
  attr :comments, :list, required: true, doc: "comment maps/structs (History.Comment shape)"
  attr :overall_feedback, :string, default: nil
  attr :show_overall, :boolean, default: true
  attr :archivable, :boolean, default: false, doc: "show Archive actions + an Archived section"
  attr :threads, :boolean, default: false, doc: "show a reply chain + reply form per comment"

  attr :select_event, :string,
    default: nil,
    doc:
      "when set, the per-comment \"Show in the doc\" control emits this LiveView event " <>
        "(with phx-value-id) to highlight the comment's anchored passage; otherwise it falls " <>
        "back to an in-page href jump"

  attr :sort, :atom,
    default: :relevance,
    doc: ":relevance (as ranked) | :position (document order)"

  slot :chat, doc: "optional right-hand chat drawer"

  slot :document,
    doc:
      "optional pre-rendered canonical manuscript body; falls back to comment passages when empty"

  def review_panes(assigns) do
    active = Enum.reject(assigns.comments, &archived?/1)
    archived = Enum.filter(assigns.comments, &archived?/1)

    # Number by relevance order (stable identity), then order the cards by the
    # chosen sort — so "#1" stays the most-relevant comment even when sorted by
    # document position.
    feedback_items = active |> Enum.with_index(1) |> sort_feedback(assigns.sort)

    assigns =
      assigns
      |> assign(:active_comments, active)
      |> assign(:archived_comments, archived)
      |> assign(:feedback_items, feedback_items)
      |> assign(:open_count, Enum.count(active, &(&1.status == :open)))

    ~H"""
    <.workspace>
      <:document>
        <.doc_pane_header label={gettext("Document")} />

        <article class="pp-scrolls flex-1 overflow-y-auto px-8 py-8 lg:px-12">
          <header class="mb-8 border-b border-base-300 pb-6">
            <p class="ds-eyebrow mb-2">{gettext("Manuscript")}</p>
            <h1 class="font-display text-2xl font-semibold leading-tight">
              {@title}
            </h1>
          </header>

          <div :if={@active_comments == []} class="font-serif text-base-content/55">
            {gettext("The manuscript text appears here once the review has passages to display.")}
          </div>

          <div class="prose prose-sm max-w-none space-y-5">
            <%= if @document != [] do %>
              {render_slot(@document)}
            <% else %>
              <p
                :for={comment <- @active_comments}
                :if={present?(comment.original_text)}
                id={"para-#{comment.id}"}
                class={[
                  "font-serif text-[15px] leading-7 text-base-content/85 scroll-mt-6",
                  comment.status == :addressed && "opacity-50",
                  comment.status == :open && "rounded-sm bg-accent/10 box-decoration-clone"
                ]}
              >
                {comment.original_text}
              </p>
            <% end %>
          </div>
        </article>
      </:document>

      <:feedback>
        <.feedback_pane_header label={gettext("Feedback")}>
          <:actions>
            <.badge color="primary" variant="soft" size="sm">
              {gettext("%{n} open", n: @open_count)}
            </.badge>
          </:actions>
        </.feedback_pane_header>

        <div class="flex-1 space-y-3.5 overflow-y-auto px-4 py-4 lg:px-5">
          <section class="collapse rounded-box border border-base-300 bg-base-100">
            <div class="collapse-title flex items-center gap-2 px-4 py-3">
              <svg
                aria-hidden="true"
                class="size-4 shrink-0 text-secondary"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.7"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M4 4h16v12H7l-3 3V4z" />
              </svg>
              <span class="font-display text-sm font-semibold">{gettext("Overall feedback")}</span>
              <.badge color="secondary" variant="soft" size="sm" class="ml-1">
                {gettext("Summary")}
              </.badge>
              <button
                type="button"
                class="btn btn-ghost btn-xs ml-auto gap-1 font-sans"
                phx-click="toggle_overall"
              >
                {if @show_overall, do: gettext("Hide"), else: gettext("Show")}
                <svg
                  aria-hidden="true"
                  class={["size-3.5 transition-transform", @show_overall && "rotate-180"]}
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <path d="M6 9l6 6 6-6" />
                </svg>
              </button>
            </div>
            <div :if={@show_overall} class="border-t border-base-300 px-4 py-3.5">
              <p class="font-serif text-sm leading-relaxed text-base-content/80">
                {@overall_feedback ||
                  gettext(
                    "The overall assessment for this manuscript will appear here once the review is complete. It summarizes the most consequential issues across the paper and the recommended path to a stronger submission."
                  )}
              </p>
            </div>
          </section>

          <div class="flex items-center justify-between gap-3 px-1 pt-1">
            <span class="font-sans text-[10px] font-semibold uppercase tracking-[0.16em] text-base-content/45">
              {gettext("Detailed feedback")}
            </span>

            <div
              :if={@active_comments != []}
              class="flex items-center gap-1 rounded-lg border border-base-300 p-0.5"
            >
              <svg
                aria-hidden="true"
                class="ml-1 size-3.5 text-base-content/40"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.7"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M7 4v16m0 0l-3-3m3 3l3-3M17 20V4m0 0l-3 3m3-3l3 3" />
              </svg>
              <button
                type="button"
                class={[
                  "rounded-md px-2 py-1 font-sans text-[11px] font-semibold transition",
                  (@sort == :relevance && "bg-base-200 text-base-content") ||
                    "text-base-content/55 hover:text-base-content"
                ]}
                phx-click="sort_feedback"
                phx-value-sort="relevance"
              >
                {gettext("By relevance")}
              </button>
              <button
                type="button"
                class={[
                  "rounded-md px-2 py-1 font-sans text-[11px] font-semibold transition",
                  (@sort == :position && "bg-base-200 text-base-content") ||
                    "text-base-content/55 hover:text-base-content"
                ]}
                phx-click="sort_feedback"
                phx-value-sort="position"
              >
                {gettext("By position")}
              </button>
            </div>
          </div>

          <p
            :if={@active_comments == []}
            class="rounded-box border border-dashed border-base-300 px-4 py-8 text-center font-serif text-sm text-base-content/55"
          >
            {gettext("No feedback on this manuscript yet.")}
          </p>

          <.feedback_comment
            :for={{comment, number} <- @feedback_items}
            comment={comment}
            index={number}
            archivable={@archivable}
            threads={@threads}
            select_event={@select_event}
          />

          <details
            :if={@archivable and @archived_comments != []}
            class="rounded-box border border-base-300 bg-base-200/40"
          >
            <summary class="cursor-pointer px-4 py-2.5 font-sans text-sm font-semibold">
              {gettext("Archived")}
              <span class="font-normal text-base-content/50">({length(@archived_comments)})</span>
            </summary>
            <div class="space-y-2 border-t border-base-300 px-4 py-3">
              <div
                :for={comment <- @archived_comments}
                class="pp-enter flex items-center justify-between gap-3"
              >
                <span class="truncate font-serif text-sm text-base-content/65">
                  {comment.suggestion || gettext("Comment")}
                </span>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs shrink-0 font-sans"
                  phx-click="unarchive"
                  phx-value-id={comment.id}
                >
                  {gettext("Restore")}
                </button>
              </div>
            </div>
          </details>
        </div>
      </:feedback>

      <:chat :if={@chat != []}>
        {render_slot(@chat)}
      </:chat>
    </.workspace>
    """
  end

  # A single detailed-feedback card: the comment, its actions, and (opt-in) its
  # archive control and reply chain.
  attr :comment, :map, required: true
  attr :index, :integer, required: true
  attr :archivable, :boolean, default: false
  attr :threads, :boolean, default: false
  attr :select_event, :string, default: nil

  defp feedback_comment(assigns) do
    assigns = assign(assigns, :replies, Map.get(assigns.comment, :replies, []))

    ~H"""
    <%= if @comment.status == :dismissed do %>
      <article class="pp-enter flex items-center gap-3 rounded-box border border-base-300 bg-base-100 px-4 py-2 opacity-65">
        <h3 class="min-w-0 flex-1 truncate font-display text-sm font-semibold leading-snug">
          <span class="mr-1 font-bold text-primary">#{@index}</span>
          {@comment.suggestion || gettext("Suggestion")}
        </h3>
        <.badge color="ghost" variant="soft" size="sm" class="shrink-0">
          {gettext("Dismissed")}
        </.badge>
        <button
          type="button"
          class="btn btn-ghost btn-xs shrink-0 gap-1.5 font-sans"
          phx-click="undo"
          phx-value-id={@comment.id}
          phx-value-action="dismissed"
        >
          <svg
            class="size-3.5"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M3 7v6h6M3 13a9 9 0 103-7.7L3 9" />
          </svg>
          {gettext("Undo")}
        </button>
      </article>
    <% else %>
      <article class={[
        "rounded-box border border-base-300 bg-base-100 p-5 transition",
        @comment.status == :addressed && "border-success/45 bg-success/5"
      ]}>
        <div class="mb-2.5 flex items-start justify-between gap-3">
          <h3 class="font-display text-base font-semibold leading-snug">
            <span class="mr-1 font-bold text-primary">#{@index}</span>
            {@comment.suggestion || gettext("Suggestion")}
          </h3>
          <.badge :if={@comment.category} color="neutral" variant="soft" size="sm" class="shrink-0">
            {category_label(@comment.category)}
          </.badge>
        </div>

        <figure
          :if={present?(@comment.original_text)}
          class="my-3 rounded-box bg-base-200/60 px-4 py-3"
        >
          <blockquote class="m-0 font-serif text-sm leading-relaxed text-base-content/70 line-through opacity-60">
            {@comment.original_text}
          </blockquote>
          <%= if @select_event do %>
            <button
              type="button"
              phx-click={@select_event}
              phx-value-id={@comment.id}
              class="mt-2 inline-flex items-center gap-1 font-sans text-xs font-medium text-primary hover:underline"
            >
              {gettext("Show in the doc")}
              <svg
                class="size-3"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M5 12h14M13 6l6 6-6 6" />
              </svg>
            </button>
          <% else %>
            <a
              href={"#para-#{@comment.id}"}
              class="mt-2 inline-flex items-center gap-1 font-sans text-xs font-medium text-primary hover:underline"
            >
              {gettext("Show in the doc")}
              <svg
                class="size-3"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M5 12h14M13 6l6 6-6 6" />
              </svg>
            </a>
          <% end %>
        </figure>

        <p
          :if={present?(@comment.suggestion)}
          class="my-2 font-serif text-sm font-medium leading-relaxed text-base-content"
        >
          {@comment.suggestion}
        </p>

        <p
          :if={present?(@comment.explanation)}
          class="font-serif text-sm leading-relaxed text-base-content/80"
        >
          {@comment.explanation}
        </p>

        <div class="mt-3.5 flex items-center gap-2">
          <.badge color={status_color(@comment.status)} variant="soft" size="sm">
            {status_label(@comment.status)}
          </.badge>

          <div class="ml-auto flex items-center gap-2">
            <button
              :if={@archivable}
              type="button"
              class="btn btn-sm btn-ghost gap-1.5 font-sans"
              phx-click="archive"
              phx-value-id={@comment.id}
            >
              <svg
                class="size-3.5"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.8"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M3 5h18v4H3zM5 9v10h14V9M9 13h6" />
              </svg>
              {gettext("Archive")}
            </button>

            <%= if @comment.status == :open do %>
              <button
                type="button"
                class="btn btn-sm btn-outline btn-success gap-1.5 font-sans"
                phx-click="address"
                phx-value-id={@comment.id}
              >
                <svg
                  class="size-3.5"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <path d="M20 6L9 17l-5-5" />
                </svg>
                {gettext("Address")}
              </button>
              <button
                type="button"
                class="btn btn-sm btn-ghost gap-1.5 font-sans"
                phx-click="dismiss"
                phx-value-id={@comment.id}
              >
                <svg
                  class="size-3.5"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <path d="M18 6L6 18M6 6l12 12" />
                </svg>
                {gettext("Dismiss")}
              </button>
            <% else %>
              <button
                type="button"
                class="btn btn-sm btn-ghost gap-1.5 font-sans"
                phx-click="undo"
                phx-value-id={@comment.id}
                phx-value-action={to_string(@comment.status)}
              >
                <svg
                  class="size-3.5"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                  <path d="M3 7v6h6M3 13a9 9 0 103-7.7L3 9" />
                </svg>
                {gettext("Undo")}
              </button>
            <% end %>
          </div>
        </div>

        <div :if={@threads} class="mt-4 border-t border-base-300 pt-3.5">
          <p class="ds-label mb-2.5 text-primary">{gettext("Discussion")}</p>

          <div :if={@replies == []} class="mb-2.5 font-serif text-xs text-base-content/45">
            {gettext("No comments yet — add one, or ask PerfectPaper.")}
          </div>

          <div class="space-y-2.5">
            <div :for={reply <- @replies} class="pp-enter flex flex-col gap-0.5">
              <span class={[
                "font-sans text-[11px] font-semibold",
                reply.role == :ai && "text-primary",
                reply.role != :ai && "text-base-content/55"
              ]}>
                {reply_author(reply)}
              </span>
              <p class="font-serif text-sm leading-relaxed text-base-content/80">{reply.text}</p>
            </div>
          </div>

          <form
            id={"reply-form-#{@comment.id}"}
            phx-submit="reply"
            class="mt-3 flex items-center gap-2"
          >
            <input type="hidden" name="comment_id" value={@comment.id} />
            <input
              type="text"
              name="body"
              autocomplete="off"
              placeholder={gettext("Add a comment or criticism…")}
              class="input input-bordered input-sm flex-1 font-sans text-xs"
            />
            <button type="submit" class="btn btn-primary btn-sm font-sans">{gettext("Reply")}</button>
            <button
              type="button"
              class="btn btn-ghost btn-sm font-sans"
              phx-click="ask_bot"
              phx-value-comment_id={@comment.id}
            >
              {gettext("Ask PerfectPaper")}
            </button>
          </form>
        </div>
      </article>
    <% end %>
    """
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Order the numbered {comment, relevance_number} pairs for display. Relevance
  # keeps the ranked order; position sorts by the comment's document position
  # (falling back to its relevance number when no position is set).
  defp sort_feedback(numbered, :position) do
    Enum.sort_by(numbered, fn {comment, number} -> Map.get(comment, :position) || number end)
  end

  defp sort_feedback(numbered, _relevance), do: numbered

  defp archived?(comment), do: Map.get(comment, :archived, false) == true

  defp reply_author(%{role: :ai}), do: "PerfectPaper"
  defp reply_author(%{role: :user}), do: gettext("You")
  defp reply_author(%{author: author}) when is_binary(author), do: author
  defp reply_author(_), do: gettext("Reviewer")

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(text) when is_binary(text), do: String.trim(text) != ""
  defp present?(_), do: false

  defp status_color(:open), do: "neutral"
  defp status_color(:dismissed), do: "ghost"
  defp status_color(:addressed), do: "success"
  defp status_color(_), do: "neutral"

  defp status_label(:open), do: gettext("Open")
  defp status_label(:dismissed), do: gettext("Dismissed")
  defp status_label(:addressed), do: gettext("Addressed")
  defp status_label(other), do: other |> to_string() |> String.capitalize()

  defp category_label(category) when is_atom(category),
    do: category |> to_string() |> category_label()

  defp category_label(category) when is_binary(category) do
    category
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp category_label(category), do: to_string(category)
end
