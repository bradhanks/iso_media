defmodule PerfectPaperWeb.DemoLive.Review do
  @moduledoc """
  The review-lifecycle demo: one public, static-data LiveView that walks through
  PerfectPaper's whole flow via a clickable step rail —

      Submit → Review → Feedback → Discuss → Resolve

  mirroring the marketing hero animation (and reusing its `pp-*` keyframes, so
  the motion matches the landing page). The Feedback and Discuss steps render the
  real `ReviewComponents.review_panes/1`, so the app matches the demo. Comment,
  reply, chat, and archive interactions all run in memory — no DB, no auth.
  """
  use PerfectPaperWeb, :live_view

  @steps [:submit, :review, :feedback, :discuss, :resolve]
  @valid_steps ~w(submit review feedback discuss resolve)
  @labels %{
    submit: "Submit",
    review: "Review",
    feedback: "Feedback",
    discuss: "Discuss",
    resolve: "Resolve"
  }

  @chat_answers [
    "I'd start with comment #1: make the §3.2 adjustment set explicit — name each backdoor path you're closing. It's the issue most likely to draw a reviewer's objection.",
    "For the scales, report Cronbach's alpha (or McDonald's omega) and the factor loadings so the psychometrics in §3.1 are defensible.",
    "On Table 4, recompute the Hispanic young-adult subgroup totals and reconcile them with §4.1, or add a footnote explaining the exclusions.",
    "Want me to draft revised language for any of these? Tell me the comment number and I'll propose specific wording."
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Demo · review lifecycle",
       step: :feedback,
       title: demo_title(),
       overall_feedback: demo_overall_feedback(),
       comments: demo_comments(),
       show_overall: true,
       sort: :relevance,
       chat_draft: "",
       chat_messages: [
         %{
           role: :ai,
           text:
             "Hi — ask me anything about this review. I can explain a comment, suggest what to prioritize, or help you draft a revision."
         }
       ]
     )}
  end

  # ── step rail ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("goto_step", %{"step" => step}, socket) when step in @valid_steps do
    {:noreply, assign(socket, :step, String.to_existing_atom(step))}
  end

  def handle_event("goto_step", _params, socket), do: {:noreply, socket}

  # ── comment status / archive ───────────────────────────────────────────────

  def handle_event("address", %{"id" => id}, socket),
    do: {:noreply, update_comment(socket, id, &%{&1 | status: :addressed})}

  def handle_event("dismiss", %{"id" => id}, socket),
    do: {:noreply, update_comment(socket, id, &%{&1 | status: :dismissed})}

  def handle_event("undo", %{"id" => id}, socket),
    do: {:noreply, update_comment(socket, id, &%{&1 | status: :open})}

  def handle_event("archive", %{"id" => id}, socket),
    do: {:noreply, update_comment(socket, id, &Map.put(&1, :archived, true))}

  def handle_event("unarchive", %{"id" => id}, socket),
    do: {:noreply, update_comment(socket, id, &Map.put(&1, :archived, false))}

  def handle_event("toggle_overall", _params, socket),
    do: {:noreply, update(socket, :show_overall, &(!&1))}

  def handle_event("sort_feedback", %{"sort" => sort}, socket),
    do: {:noreply, assign(socket, :sort, if(sort == "position", do: :position, else: :relevance))}

  # ── comment chain (replies) ─────────────────────────────────────────────────

  def handle_event("reply", %{"comment_id" => id, "body" => body}, socket) do
    case String.trim(body) do
      "" -> {:noreply, socket}
      text -> {:noreply, add_reply(socket, id, %{role: :user, author: "You", text: text})}
    end
  end

  def handle_event("ask_bot", %{"comment_id" => id}, socket),
    do: {:noreply, add_reply(socket, id, %{role: :ai, text: bot_reply_for(socket, id)})}

  # ── chat column (Discuss step) ──────────────────────────────────────────────

  def handle_event("update_draft", %{"message" => message}, socket),
    do: {:noreply, assign(socket, :chat_draft, message)}

  def handle_event("send", %{"message" => message}, socket) do
    case String.trim(message) do
      "" ->
        {:noreply, socket}

      text ->
        messages =
          socket.assigns.chat_messages ++
            [%{role: :user, text: text}, %{role: :ai, text: chat_answer(socket)}]

        {:noreply, assign(socket, chat_messages: messages, chat_draft: "")}
    end
  end

  # ── render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :addressed_count, Enum.count(assigns.comments, &(&1.status == :addressed)))

    ~H"""
    <.app
      title={@title}
      scroll={false}
      flash={@flash}
      current_scope={@current_scope}
    >
      <:actions>
        <.link navigate={~p"/demo"} class="btn btn-ghost btn-sm font-sans">All demos</.link>
      </:actions>

      <.step_rail step={@step} />

      <%= case @step do %>
        <% :submit -> %>
          <.submit_step />
        <% :review -> %>
          <.review_step title={@title} />
        <% :feedback -> %>
          <.review_panes
            title={@title}
            comments={@comments}
            overall_feedback={@overall_feedback}
            show_overall={@show_overall}
            sort={@sort}
            archivable
            threads
          />
        <% :discuss -> %>
          <.review_panes
            title={@title}
            comments={@comments}
            overall_feedback={@overall_feedback}
            show_overall={@show_overall}
            sort={@sort}
            archivable
            threads
          >
            <:chat>
              <.chat_panel
                title="Ask about this review"
                on_submit="send"
                on_change="update_draft"
                draft={@chat_draft}
              >
                <:messages>
                  <div
                    :for={message <- @chat_messages}
                    class={[
                      "pp-enter max-w-[85%] rounded-2xl px-3.5 py-2 font-serif text-sm leading-relaxed",
                      (message.role == :user &&
                         "self-end rounded-br-sm bg-primary text-primary-content") ||
                        "self-start rounded-bl-sm border border-base-300 bg-base-100 text-base-content/85"
                    ]}
                  >
                    {message.text}
                  </div>
                </:messages>
              </.chat_panel>
            </:chat>
          </.review_panes>
        <% :resolve -> %>
          <.resolve_step title={@title} addressed={@addressed_count} total={length(@comments)} />
      <% end %>
    </.app>
    """
  end

  # ── step rail ─────────────────────────────────────────────────────────────

  attr :step, :atom, required: true

  defp step_rail(assigns) do
    current = Enum.find_index(@steps, &(&1 == assigns.step))

    rail =
      @steps
      |> Enum.with_index()
      |> Enum.map(fn {step, i} ->
        %{step: step, label: @labels[step], num: String.pad_leading("#{i + 1}", 2, "0"), index: i}
      end)

    assigns = assign(assigns, current: current, rail: rail)

    ~H"""
    <div class="shrink-0 border-b border-base-300 bg-base-100 px-4 py-3">
      <div class="pp-rail mx-auto flex max-w-3xl items-center">
        <%= for item <- @rail do %>
          <span
            :if={item.index > 0}
            class="pp-rail-line mx-2 h-0.5 flex-1 overflow-hidden bg-base-300 sm:mx-3"
          >
            <i class={[
              "block h-full origin-left bg-primary transition-transform duration-500",
              (item.index <= @current && "scale-x-100") || "scale-x-0"
            ]}>
            </i>
          </span>
          <button
            type="button"
            class={[
              "pp-rail-step flex flex-col gap-0.5 text-left",
              (item.index == @current && "pp-active") || (item.index < @current && "pp-done")
            ]}
            phx-click="goto_step"
            phx-value-step={to_string(item.step)}
          >
            <span class="pp-rail-num font-sans text-[11px] font-bold text-base-content/35">
              {item.num}
            </span>
            <span class="pp-rail-label font-sans text-[12.5px] font-semibold whitespace-nowrap text-base-content/45">
              {item.label}
            </span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Submit step ─────────────────────────────────────────────────────────────

  defp submit_step(assigns) do
    ~H"""
    <div class="grid flex-1 place-items-center overflow-y-auto bg-base-200/35 p-6">
      <div class="relative w-full max-w-md">
        <div class="grid place-items-center gap-3 rounded-box border-2 border-dashed border-primary/45 bg-primary/5 px-8 py-14 text-center">
          <div class="grid size-12 place-items-center rounded-xl bg-primary/10 text-primary">
            <svg
              class="size-6"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.7"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M12 16V4m0 0l-4 4m4-4l4 4" /><path d="M4 16v2a2 2 0 002 2h12a2 2 0 002-2v-2" />
            </svg>
          </div>
          <p class="font-display text-lg font-semibold">Drop your manuscript</p>
          <p class="font-serif text-sm text-base-content/60">
            Word document (.docx) — up to 25 MB.
          </p>
          <p class="pp-dz-done font-sans text-sm font-semibold text-success">
            manuscript.docx · uploaded
          </p>
        </div>
        <div class="pp-pdf-card absolute -bottom-4 right-2 w-32 rounded-[10px] border border-base-300 bg-base-100 p-2.5 shadow-lg">
          <div class="font-sans text-[8px] font-bold tracking-[0.1em] text-error">PDF</div>
          <div class="mt-1 font-sans text-[10px] text-base-content/70">manuscript.pdf</div>
          <div class="mt-1.5 h-1 w-[90%] rounded bg-base-content/10"></div>
          <div class="mt-1.5 h-1 w-[70%] rounded bg-base-content/10"></div>
        </div>
      </div>
    </div>
    """
  end

  # ── Review step (scanning) ───────────────────────────────────────────────────

  attr :title, :string, required: true

  defp review_step(assigns) do
    ~H"""
    <.workspace>
      <:document>
        <.doc_pane_header label="Document" />
        <div class="relative flex-1 overflow-hidden px-8 py-8 lg:px-12">
          <p class="ds-eyebrow mb-2">Manuscript</p>
          <h1 class="mb-6 font-display text-2xl font-semibold leading-tight">{@title}</h1>
          <div class="space-y-3">
            <div
              :for={w <- ~w(100% 94% 88% 96% 72% 90% 84%)}
              class="h-2.5 rounded bg-base-content/10"
              style={"width:#{w}"}
            >
            </div>
          </div>
          <div class="pp-doc-scan absolute left-0 right-0 h-16 border-t border-primary/55 bg-gradient-to-b from-transparent via-primary/20 to-transparent">
          </div>
          <div class="absolute bottom-4 left-8 flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-3 py-1.5 font-sans text-xs shadow-md lg:left-12">
            <span class="loading loading-spinner loading-xs text-primary"></span>
            Reading §3.2 — methods
          </div>
        </div>
      </:document>
      <:feedback>
        <.feedback_pane_header label="Feedback" />
        <div class="flex flex-1 flex-col gap-3 overflow-y-auto px-4 py-4 lg:px-5">
          <div :for={_ <- 1..3} class="rounded-box border border-base-300 bg-base-100 p-4">
            <div class="skeleton h-3 w-1/2"></div>
            <div class="skeleton mt-2.5 h-2 w-full"></div>
            <div class="skeleton mt-1.5 h-2 w-5/6"></div>
          </div>
        </div>
      </:feedback>
    </.workspace>
    """
  end

  # ── Resolve step ─────────────────────────────────────────────────────────────

  attr :title, :string, required: true
  attr :addressed, :integer, required: true
  attr :total, :integer, required: true

  defp resolve_step(assigns) do
    ~H"""
    <.workspace>
      <:document>
        <.doc_pane_header label="Document" />
        <div class="flex-1 overflow-y-auto px-8 py-8 lg:px-12">
          <p class="ds-eyebrow mb-2">Manuscript</p>
          <h1 class="mb-6 font-display text-2xl font-semibold leading-tight">{@title}</h1>
          <div class="space-y-3 opacity-60">
            <div
              :for={w <- ~w(100% 94% 88% 96% 72% 90% 84% 78%)}
              class="h-2.5 rounded bg-base-content/10"
              style={"width:#{w}"}
            >
            </div>
          </div>
        </div>
      </:document>
      <:feedback>
        <.feedback_pane_header label="Feedback" />
        <div class="flex flex-1 flex-col gap-4 overflow-y-auto px-4 py-5 lg:px-5">
          <div class="rounded-box border border-success/40 bg-success/5 p-5 text-center">
            <div class="pp-pop mx-auto mb-3 grid size-12 place-items-center rounded-full bg-success text-success-content">
              <svg
                class="size-6"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M20 6L9 17l-5-5" />
              </svg>
            </div>
            <h2 class="font-display text-lg font-semibold">Submission-ready</h2>
            <p class="mt-1 font-serif text-sm text-base-content/70">
              Every comment has been addressed. Export your revised manuscript and submit with confidence.
            </p>
          </div>

          <div class="rounded-box border border-base-300 bg-base-100 p-4">
            <div class="flex justify-between font-sans text-[11px] font-semibold">
              <span>Comments addressed</span>
              <span class="text-success">{@total} / {@total}</span>
            </div>
            <div class="mt-2 h-2 overflow-hidden rounded-full bg-base-300">
              <i class="pp-progress block h-full rounded-full bg-success"></i>
            </div>
          </div>

          <button type="button" class="btn btn-primary mt-auto font-sans font-semibold">
            <svg
              class="size-4"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M12 4v12m0 0l-4-4m4 4l4-4" /><path d="M4 18h16" />
            </svg>
            Export revised manuscript
          </button>
        </div>
      </:feedback>
    </.workspace>
    """
  end

  # ── in-memory helpers ─────────────────────────────────────────────────────

  defp update_comment(socket, id, fun) do
    comments =
      Enum.map(socket.assigns.comments, fn comment ->
        if comment.id == id, do: fun.(comment), else: comment
      end)

    assign(socket, :comments, comments)
  end

  defp add_reply(socket, id, reply) do
    update_comment(socket, id, fn comment ->
      Map.update(comment, :replies, [reply], &(&1 ++ [reply]))
    end)
  end

  defp chat_answer(socket) do
    asked = Enum.count(socket.assigns.chat_messages, &(&1.role == :user))
    Enum.at(@chat_answers, rem(asked, length(@chat_answers)))
  end

  defp bot_reply_for(socket, id) do
    comment = Enum.find(socket.assigns.comments, &(&1.id == id))

    case comment && comment.suggestion do
      nil ->
        "Happy to help with this comment — tell me what you'd like to change and I'll draft it."

      suggestion ->
        "On \"#{suggestion}\" — I can draft a revision and cite the relevant section. Want me to propose specific wording you can paste into the manuscript?"
    end
  end

  # ── static sample review ────────────────────────────────────────────────────

  defp demo_title, do: "Rural–Urban Divides and Cultural Dynamics in Vaccine Hesitancy"

  defp demo_overall_feedback do
    "A timely, well-powered study with a clear rural–urban framing. Three things " <>
      "to strengthen before submission: make the causal-adjustment strategy in §3.2 " <>
      "explicit, report reliability for the hesitancy scales, and reconcile the " <>
      "subgroup counts in Table 4 with the totals in §4.1. Tightening the causal " <>
      "language in the Discussion will help it read as carefully as it was designed."
  end

  defp demo_comments do
    [
      %{
        id: "1",
        position: 3,
        status: :open,
        archived: false,
        category: "methods",
        suggestion: "Causal adjustment is underspecified in §3.2",
        original_text:
          "As shown in Figure 2, directed acyclic graphs encoded a priori knowledge for estimating the total effect of rural residence on hesitancy.",
        explanation:
          "State each backdoor path you are closing and cite the assumption behind every included covariate — reviewers will want the minimally-sufficient adjustment set made explicit.",
        replies: [
          %{
            role: :ai,
            text:
              "The DAG in Figure 2 implies you're conditioning on a collider (clinic access). Closing that path may bias the estimate — worth a sentence on why it's included."
          },
          %{
            role: :reviewer,
            author: "R. Mehta (co-author)",
            text: "Agreed. I can pull the original adjustment set from our preregistration."
          }
        ]
      },
      %{
        id: "2",
        position: 2,
        status: :open,
        archived: false,
        category: "statistics",
        suggestion: "Report reliability for the three hesitancy scales",
        original_text:
          "We constructed three factor-derived scales capturing confidence, complacency, and convenience.",
        explanation:
          "Section 3.1 anchors your conclusions on these scales. Add Cronbach's alpha (or McDonald's omega) and the factor loadings so readers can judge their psychometric security.",
        replies: [
          %{
            role: :ai,
            text:
              "If alpha is below ~0.7 for the convenience scale, consider reporting omega instead and noting the item that drags it down."
          }
        ]
      },
      %{
        id: "3",
        position: 6,
        status: :open,
        archived: false,
        category: "data",
        suggestion: "Subgroup counts in Table 4 don't reconcile with §4.1",
        original_text: nil,
        explanation:
          "The Hispanic young-adult subgroup counts in Table 4 don't add up to the totals reported in Section 4.1. Reconcile the figures or state the exclusions that explain the gap.",
        replies: []
      },
      %{
        id: "4",
        position: 1,
        status: :open,
        archived: false,
        category: "clarity",
        suggestion: "Define \"rural\" and \"urban\" operationally",
        original_text:
          "Rural and urban communities diverged sharply in their acceptance of the HPV vaccine.",
        explanation:
          "The rural–urban contrast is central to the paper but never defined. State the classification (e.g. RUCA codes) and the threshold you used.",
        replies: []
      },
      %{
        id: "5",
        position: 7,
        status: :open,
        archived: false,
        category: "claims",
        suggestion: "Soften unsupported causal language in the Discussion",
        original_text:
          "These cultural dynamics drive vaccine refusal across the rural United States.",
        explanation:
          "Your design supports association, not population-level causation. Hedge \"drive\" to \"are associated with\", or justify the causal claim with the identification strategy from §3.2.",
        replies: []
      },
      %{
        id: "6",
        position: 4,
        status: :open,
        archived: false,
        category: "methods",
        suggestion: "Account for excluded responses with a participant-flow note",
        original_text: nil,
        explanation:
          "About 12% of responses were dropped without a stated rule. Add a short CONSORT-style flow describing who was excluded and why, so the analytic sample is reproducible.",
        replies: []
      },
      %{
        id: "7",
        position: 5,
        status: :open,
        archived: false,
        category: "figures",
        suggestion: "Align Figure 2 axis labels with the §2.4 notation",
        original_text: "Figure 2. Adjusted associations between residence and vaccine hesitancy.",
        explanation:
          "Figure 2 uses β where the text uses θ for the same quantity. Use one symbol throughout so the figure and the model section agree.",
        replies: []
      }
    ]
  end
end
