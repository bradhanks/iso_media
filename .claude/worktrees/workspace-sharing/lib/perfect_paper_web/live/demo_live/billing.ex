defmodule PerfectPaperWeb.DemoLive.Billing do
  @moduledoc """
  Public, static-data demo of the billing surface — the subscription plans and
  one-time credit packs from `PerfectPaper.Billing.Prices`, with a sample
  current-plan summary. Reads plan fields defensively so it renders under either
  catalogue shape.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.Billing.Prices

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Demo · billing",
       plans: Prices.list(),
       packs: safe_packs()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app
      active={:billing}
      title="Subscription & credits"
      flash={@flash}
      current_scope={@current_scope}
    >
      <:actions>
        <.link navigate={~p"/demo"} class="btn btn-ghost btn-sm font-sans">All demos</.link>
      </:actions>

      <div class="mx-auto w-full max-w-4xl space-y-10">
        <div class="rounded-box border border-base-300 bg-base-200/40 px-5 py-4">
          <p class="font-sans text-sm">
            You're on <strong>free previews</strong> — a preview of the full review, on us.
            Upgrade any time for full reviews every month.
          </p>
        </div>

        <section>
          <h2 class="ds-h3 mb-5">Monthly plans</h2>
          <div class="grid gap-5 md:grid-cols-3">
            <article
              :for={plan <- @plans}
              class={[
                "flex flex-col rounded-box border bg-base-100 p-6",
                (popular?(plan) && "border-primary shadow-md") || "border-base-300"
              ]}
            >
              <div class="flex items-baseline justify-between">
                <h3 class="font-display text-xl font-semibold">{plan_name(plan)}</h3>
                <span class="font-sans text-lg font-semibold text-primary">{plan_price(plan)}</span>
              </div>
              <p :if={cadence(plan)} class="mt-1 font-sans text-xs text-base-content/55">
                {cadence(plan)}
              </p>
              <ul class="mt-4 flex-1 space-y-2">
                <li
                  :for={feature <- features(plan)}
                  class="flex items-start gap-2 font-serif text-sm text-base-content/75"
                >
                  <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-success" />
                  {feature}
                </li>
              </ul>
              <button type="button" class="btn btn-outline btn-block mt-6 font-sans font-semibold">
                Choose {plan_name(plan)}
              </button>
            </article>
          </div>
        </section>

        <section :if={@packs != []}>
          <h2 class="ds-h3 mb-5">One-time credit packs</h2>
          <div class="grid gap-5 md:grid-cols-3">
            <article
              :for={pack <- @packs}
              class="flex flex-col rounded-box border border-base-300 bg-base-100 p-6"
            >
              <div class="flex items-baseline justify-between">
                <h3 class="font-display text-lg font-semibold">{plan_name(pack)}</h3>
                <span class="font-sans text-lg font-semibold text-primary">{plan_price(pack)}</span>
              </div>
              <p :if={cadence(pack)} class="mt-1 font-sans text-xs text-base-content/55">
                {cadence(pack)}
              </p>
              <button type="button" class="btn btn-ghost btn-block mt-6 font-sans font-semibold">
                Buy
              </button>
            </article>
          </div>
        </section>
      </div>
    </.app>
    """
  end

  # Defensive field access — works whether Prices yields the rich plan_map or a
  # legacy product map.
  defp plan_name(%{name: name}) when is_binary(name), do: name
  defp plan_name(%{plan: plan}), do: plan |> to_string() |> String.capitalize()
  defp plan_name(_), do: "Plan"

  defp plan_price(%{price_label: label}) when is_binary(label), do: label
  defp plan_price(%{price_cents: _} = product), do: Prices.price_label(product)
  defp plan_price(_), do: ""

  defp cadence(plan), do: Map.get(plan, :cadence)
  defp features(plan), do: Map.get(plan, :features, [])
  defp popular?(plan), do: Map.get(plan, :popular?, false)

  defp safe_packs do
    Prices.credit_packs()
  rescue
    _ -> []
  end
end
