defmodule PerfectPaperWeb.DemoLive.Hub do
  @moduledoc """
  Public index of the interactive demos. Links each demo (review lifecycle and
  the account surfaces) so visitors can click through the product with sample
  data — no account required.
  """
  use PerfectPaperWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Interactive demos")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section class="ds-container py-16 lg:py-24">
        <p class="ds-eyebrow mb-3">Interactive demos</p>
        <h1 class="ds-h1 max-w-3xl">See PerfectPaper work — with your hands on it</h1>
        <p class="ds-lead mt-4 max-w-2xl text-base-content/70">
          Click through the whole review lifecycle and the tools around it. Everything below
          is live and interactive, running on a sample manuscript — no sign-up needed.
        </p>

        <div class="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          <.link
            :for={card <- cards()}
            navigate={card.href}
            class="group flex flex-col rounded-box border border-base-300 bg-base-100 p-6 transition hover:border-primary/40 hover:shadow-md"
          >
            <span class="font-sans text-[11px] font-bold uppercase tracking-[0.16em] text-primary">
              {card.eyebrow}
            </span>
            <h2 class="mt-2 font-display text-xl font-semibold">{card.title}</h2>
            <p class="mt-2 flex-1 font-serif text-sm leading-relaxed text-base-content/70">
              {card.body}
            </p>
            <span class="mt-4 inline-flex items-center gap-1 font-sans text-sm font-medium text-primary">
              Open demo
              <svg
                class="size-4 transition-transform group-hover:translate-x-0.5"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M5 12h14M13 6l6 6-6 6" />
              </svg>
            </span>
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp cards do
    [
      %{
        eyebrow: "The full flow",
        title: "Review lifecycle",
        body:
          "Submit → Review → Feedback → Discuss → Resolve. Walk the whole loop, address comments, chat with PerfectPaper, and export a submission-ready paper.",
        href: ~p"/demo/review"
      },
      %{
        eyebrow: "Your reviews",
        title: "History",
        body: "Every manuscript you've reviewed, with status and comment counts at a glance.",
        href: ~p"/demo/history"
      },
      %{
        eyebrow: "Plans & credits",
        title: "Billing",
        body: "Subscriptions and one-time credit packs — pick the plan that fits how you write.",
        href: ~p"/demo/billing"
      },
      %{
        eyebrow: "Free credits",
        title: "Earn",
        body: "Invite colleagues and earn review credits. Track your referral link and balance.",
        href: ~p"/demo/earn"
      }
    ]
  end
end
