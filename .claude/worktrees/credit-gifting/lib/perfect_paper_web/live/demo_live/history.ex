defmodule PerfectPaperWeb.DemoLive.History do
  @moduledoc """
  Public, static-data demo of the reviews list — every manuscript a writer has
  reviewed, with status and comment counts, linking into the review lifecycle.
  """
  use PerfectPaperWeb, :live_view

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Demo · history", reviews: reviews())}

  @impl true
  def render(assigns) do
    ~H"""
    <.app active={:history} title="History" flash={@flash} current_scope={@current_scope}>
      <:actions>
        <.link navigate={~p"/demo"} class="btn btn-ghost btn-sm font-sans">All demos</.link>
      </:actions>

      <div class="mx-auto w-full max-w-3xl">
        <h1 class="ds-h2 mb-1">Your reviews</h1>
        <p class="mb-6 font-serif text-base-content/60">A sample of past manuscript reviews.</p>

        <ul class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300 bg-base-100">
          <li :for={review <- @reviews}>
            <.link
              navigate={~p"/demo/review"}
              class="flex items-center gap-4 px-5 py-4 transition hover:bg-base-200/50"
            >
              <div class="min-w-0 flex-1">
                <p class="truncate font-display text-base font-semibold">{review.title}</p>
                <p class="mt-0.5 font-sans text-xs text-base-content/50">
                  {review.date} · {review.comments} comments
                </p>
              </div>
              <.badge color={status_color(review.status)} variant="soft" size="sm" class="shrink-0">
                {status_label(review.status)}
              </.badge>
            </.link>
          </li>
        </ul>
      </div>
    </.app>
    """
  end

  defp status_color(:complete), do: "success"
  defp status_color(:in_review), do: "primary"
  defp status_color(_), do: "neutral"

  defp status_label(:complete), do: "Complete"
  defp status_label(:in_review), do: "In review"
  defp status_label(other), do: other |> to_string() |> String.capitalize()

  defp reviews do
    [
      %{
        title: "Rural–Urban Divides and Cultural Dynamics in Vaccine Hesitancy",
        date: "May 30, 2026",
        comments: 7,
        status: :complete
      },
      %{
        title: "Chaotic balanced state in a model of cortical circuits",
        date: "May 22, 2026",
        comments: 3,
        status: :complete
      },
      %{
        title: "Robust market interventions under model uncertainty",
        date: "May 14, 2026",
        comments: 5,
        status: :in_review
      },
      %{
        title: "Inference in molecular population genetics",
        date: "Apr 28, 2026",
        comments: 7,
        status: :complete
      }
    ]
  end
end
