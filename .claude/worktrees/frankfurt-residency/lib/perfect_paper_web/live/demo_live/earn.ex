defmodule PerfectPaperWeb.DemoLive.Earn do
  @moduledoc """
  Public, static-data demo of the Earn surface — referral link, credit balance,
  ways to earn, and a ledger of recent credit events. Copy-to-clipboard is a
  no-op affordance in the demo.
  """
  use PerfectPaperWeb, :live_view

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Demo · earn credits", balance: 12)}

  @impl true
  def render(assigns) do
    ~H"""
    <.app active={:earn} title="Earn credits" flash={@flash} current_scope={@current_scope}>
      <:actions>
        <.link navigate={~p"/demo"} class="btn btn-ghost btn-sm font-sans">All demos</.link>
      </:actions>

      <div class="mx-auto w-full max-w-3xl space-y-6">
        <div class="rounded-box border border-base-300 bg-base-100 p-6">
          <p class="ds-eyebrow mb-1">Credit balance</p>
          <p class="font-display text-4xl font-semibold">{@balance}</p>
          <p class="mt-1 font-serif text-sm text-base-content/60">
            credits available — each full review costs one credit.
          </p>
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-6">
          <h2 class="font-display text-lg font-semibold">Invite colleagues, earn credits</h2>
          <p class="mt-1 font-serif text-sm text-base-content/70">
            You and your colleague each get a free review credit when they run their first review.
          </p>
          <div class="mt-4 flex items-center gap-2">
            <input
              type="text"
              readonly
              value="https://perfectpaper.ink/r/kepka-9F2A"
              class="input input-bordered flex-1 font-sans text-sm"
            />
            <button type="button" class="btn btn-primary font-sans font-semibold">Copy link</button>
          </div>
        </div>

        <div class="grid gap-4 sm:grid-cols-3">
          <div :for={way <- ways()} class="rounded-box border border-base-300 bg-base-100 p-5">
            <p class="font-display text-2xl font-semibold text-primary">+{way.credits}</p>
            <p class="mt-1 font-sans text-sm font-semibold">{way.title}</p>
            <p class="mt-1 font-serif text-xs leading-relaxed text-base-content/60">{way.body}</p>
          </div>
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-6">
          <h2 class="mb-3 font-display text-lg font-semibold">Recent activity</h2>
          <ul class="divide-y divide-base-300">
            <li :for={event <- ledger()} class="flex items-center justify-between py-2.5">
              <span class="font-serif text-sm text-base-content/75">{event.label}</span>
              <span class={[
                "font-sans text-sm font-semibold",
                (event.amount > 0 && "text-success") || "text-base-content/60"
              ]}>
                {if event.amount > 0, do: "+#{event.amount}", else: event.amount}
              </span>
            </li>
          </ul>
        </div>
      </div>
    </.app>
    """
  end

  defp ways do
    [
      %{
        credits: 1,
        title: "Refer a colleague",
        body: "They run their first review; you both get a credit."
      },
      %{
        credits: 3,
        title: "Cite us in your methods",
        body: "Mention PerfectPaper in an acknowledgement."
      },
      %{credits: 5, title: "Bring your lab", body: "Five colleagues join from your invite."}
    ]
  end

  defp ledger do
    [
      %{label: "Referral bonus — A. Okafor joined", amount: 1},
      %{label: "Welcome credits", amount: 10},
      %{label: "Review: Vaccine Hesitancy", amount: -1},
      %{label: "Referral bonus — J. Lim joined", amount: 1},
      %{label: "Review: Cortical circuits", amount: -1}
    ]
  end
end
