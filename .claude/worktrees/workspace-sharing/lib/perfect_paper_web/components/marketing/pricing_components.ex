defmodule PerfectPaperWeb.Marketing.PricingComponents do
  @moduledoc """
  Pricing components for PerfectPaper's marketing pages.

  These render PerfectPaper's real plan catalogue (Starter, Professional, Advanced) and a
  tasteful, complement-not-replace comparison against a freelance copy-editor.
  Pure, presentational function components on daisyUI semantic classes and the
  `paper` theme. Headlines use `font-display` (Fraunces), reading copy uses
  `font-serif` (Newsreader), and prices/labels use `font-sans` (Outfit) with a
  mono numeral accent. Gold/accent is used for fills only — never as text.

  Includes:

  - `pricing_tiers/1` — three-up plan cards with feature lists and a highlighted plan
  - `pricing_comparison/1` — PerfectPaper alongside a freelance copy-editor (illustrative)
  """
  use Phoenix.Component
  use PerfectPaperWeb, :verified_routes
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders PerfectPaper's three subscription plans as a side-by-side card row.

  Pass `plans` as a list of maps mirroring `PerfectPaper.Billing.Prices` — each
  with a `:name`, `:price` label, optional `:cadence`, a `:tagline`, a list of
  `:features`, and optional `:popular` and CTA overrides. Defaults render the
  current Starter / Professional / Advanced catalogue.

  ## Example

      <.pricing_tiers
        eyebrow="Plans"
        title="Pricing that scales with your writing"
        subtitle="Start free. Upgrade when a deadline is close and the stakes are high."
      />
  """
  attr :eyebrow, :string, default: nil
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil

  attr :plans, :list,
    default: nil,
    doc: "override the default Starter/Professional/Advanced catalogue"

  attr :cta_link, :string, default: nil
  attr :class, :string, default: nil

  def pricing_tiers(assigns) do
    assigns =
      assigns
      |> assign_new(:plans, fn -> default_plans() end)
      |> assign_new(:cta_link, fn -> ~p"/users/register" end)
      |> Map.update!(:eyebrow, fn v -> v || gettext("Plans") end)
      |> Map.update!(:title, fn v -> v || gettext("Pricing that scales with your writing") end)

    ~H"""
    <section class={["bg-base-100 py-20 lg:py-28", @class]}>
      <div class="ds-container">
        <div class="text-center max-w-2xl mx-auto mb-16">
          <div
            :if={@eyebrow}
            class="ds-eyebrow flex items-center justify-center gap-3 text-base-content/60 mb-6"
          >
            <span class="inline-block h-px w-8 bg-accent"></span>
            <span>{@eyebrow}</span>
            <span class="inline-block h-px w-8 bg-accent"></span>
          </div>
          <h2 class="font-display font-semibold tracking-[-0.01em] text-3xl md:text-4xl text-base-content">
            {@title}
          </h2>
          <p :if={@subtitle} class="mt-4 font-serif text-lg text-base-content/70 leading-relaxed">
            {@subtitle}
          </p>
        </div>

        <div class="grid md:grid-cols-3 gap-6 lg:gap-8 items-stretch">
          <div
            :for={plan <- @plans}
            class={[
              "relative flex flex-col bg-base-100 border p-8",
              if(plan[:popular],
                do: "border-primary/40 ring-1 ring-primary/30",
                else: "border-base-content/10"
              )
            ]}
          >
            <span
              :if={plan[:popular]}
              class="absolute -top-3 left-8 badge badge-primary font-sans text-xs font-semibold"
            >
              {gettext("Most popular")}
            </span>

            <div class="ds-eyebrow text-base-content/55 mb-3">
              {plan.name}
            </div>

            <div class="flex items-baseline gap-1.5">
              <span class="font-display font-semibold text-4xl tracking-tight text-base-content">
                {plan.price}
              </span>
              <span :if={plan[:cadence]} class="font-sans text-sm text-base-content/50">
                {plan.cadence}
              </span>
            </div>

            <p
              :if={plan[:tagline]}
              class="mt-3 font-serif text-sm text-base-content/65 leading-relaxed"
            >
              {plan.tagline}
            </p>

            <ul class="mt-7 space-y-3 flex-1">
              <li :for={feature <- plan.features} class="flex items-start gap-2.5">
                <.icon name="hero-check" class="size-4 shrink-0 mt-0.5 text-primary" />
                <span class="font-sans text-sm text-base-content/75 leading-snug">{feature}</span>
              </li>
            </ul>

            <div class="mt-8">
              <.link
                navigate={@cta_link}
                class={[
                  "btn btn-block font-sans font-semibold",
                  if(plan[:popular], do: "btn-primary", else: "btn-outline")
                ]}
              >
                {plan[:cta] || gettext("Get started")}
              </.link>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders a tasteful side-by-side comparison of PerfectPaper alongside a
  freelance copy-editor.

  The framing is complement-not-replace: a human editor remains invaluable for
  the deep, final pass — PerfectPaper gives you a careful first read for every
  draft, at a fraction of the turnaround and cost. Numbers are illustrative.

  ## Example

      <.pricing_comparison />
      <.pricing_comparison class="mt-8" />
  """
  attr :class, :string, default: nil

  def pricing_comparison(assigns) do
    ~H"""
    <section class={["bg-base-100 py-20 lg:py-28", @class]}>
      <div class="max-w-5xl mx-auto px-5 sm:px-6 lg:px-8">
        <div class="text-center max-w-2xl mx-auto mb-12">
          <h2 class="font-display font-semibold tracking-[-0.01em] text-3xl md:text-4xl text-base-content">
            {gettext("PerfectPaper and a freelance copy-editor")}
          </h2>
          <p class="mt-4 font-serif text-lg text-base-content/70 leading-relaxed">
            {gettext(
              "A great copy-editor is worth every penny for the final pass. PerfectPaper gives every draft along the way the same kind of careful read — in minutes, so you arrive at that final pass with cleaner prose."
            )}
          </p>
        </div>

        <div class="grid md:grid-cols-2 gap-6 lg:gap-8 items-stretch">
          <%!-- Freelance copy-editor column --%>
          <div class="flex flex-col bg-base-100 border border-base-content/10 p-7">
            <div class="flex items-center gap-2 mb-5">
              <span class="font-display text-lg font-semibold text-base-content">
                {gettext("A freelance copy-editor")}
              </span>
              <span class="badge badge-ghost font-sans badge-sm">{gettext("per pass")}</span>
            </div>

            <div class="flex items-baseline gap-1.5">
              <span class="font-display font-semibold text-3xl tracking-tight text-base-content">
                $0.02–$0.05
              </span>
              <span class="font-sans text-sm text-base-content/55">
                {gettext("per word, per pass")}
              </span>
            </div>
            <p class="mt-2 font-sans text-sm text-base-content/55">
              {gettext("Roughly $150–$400 for a single read of an 8,000-word paper.")}
            </p>

            <ul class="mt-6 space-y-2.5 pt-5 border-t border-base-content/10 flex-1">
              <li class="flex items-start gap-2 font-sans text-sm text-base-content/60">
                <.icon name="hero-clock" class="size-4 shrink-0 mt-0.5 text-base-content/40" />
                {gettext("Days to weeks of turnaround")}
              </li>
              <li class="flex items-start gap-2 font-sans text-sm text-base-content/60">
                <.icon name="hero-arrow-path" class="size-4 shrink-0 mt-0.5 text-base-content/40" />
                {gettext("New fee for every revision and re-read")}
              </li>
              <li class="flex items-start gap-2 font-sans text-sm text-base-content/60">
                <.icon name="hero-user" class="size-4 shrink-0 mt-0.5 text-base-content/40" />
                {gettext("Availability depends on their schedule")}
              </li>
              <li class="flex items-start gap-2 font-sans text-sm text-base-content">
                <.icon name="hero-sparkles" class="size-4 shrink-0 mt-0.5 text-accent" />
                {gettext("Deep human judgment for the final pass")}
              </li>
            </ul>
          </div>

          <%!-- PerfectPaper column --%>
          <div class="flex flex-col bg-base-100 border border-primary/40 ring-1 ring-primary/30 p-7">
            <div class="flex items-center gap-2 mb-5">
              <span class="font-display text-lg font-semibold text-primary">PerfectPaper</span>
              <span class="badge badge-primary font-sans badge-sm">{gettext("every draft")}</span>
            </div>

            <div class="flex items-baseline gap-1.5">
              <span class="font-display font-semibold text-3xl tracking-tight text-base-content">
                {gettext("Free preview")}
              </span>
              <span class="font-sans text-sm text-base-content/55">
                {gettext("— then $40/mo for full reviews")}
              </span>
            </div>
            <p class="mt-2 font-sans text-sm text-base-content/55">
              {gettext("Re-read each new draft as you revise — included in your plan.")}
            </p>

            <ul class="mt-6 space-y-2.5 pt-5 border-t border-base-content/10 flex-1">
              <li class="flex items-start gap-2 font-sans text-sm text-base-content/75">
                <.icon name="hero-check" class="size-4 shrink-0 mt-0.5 text-primary" />
                {gettext("Comments back in minutes, any time of day")}
              </li>
              <li class="flex items-start gap-2 font-sans text-sm text-base-content/75">
                <.icon name="hero-check" class="size-4 shrink-0 mt-0.5 text-primary" />
                {gettext("Revisions re-read as part of your plan — no new fee per pass")}
              </li>
              <li class="flex items-start gap-2 font-sans text-sm text-base-content/75">
                <.icon name="hero-check" class="size-4 shrink-0 mt-0.5 text-primary" />
                {gettext("Argument, structure, citations, and prose")}
              </li>
              <li class="flex items-start gap-2 font-sans text-sm text-base-content/75">
                <.icon name="hero-check" class="size-4 shrink-0 mt-0.5 text-primary" />
                {gettext("A clean draft to hand your human editor")}
              </li>
            </ul>

            <div class="mt-7">
              <.link
                navigate={~p"/users/register"}
                class="btn btn-primary btn-block font-sans font-semibold"
              >
                {gettext("Start a free read")}
              </.link>
            </div>
          </div>
        </div>

        <p class="mt-6 font-sans text-xs text-base-content/40 text-center">
          {gettext(
            "Copy-editing rates are illustrative industry ranges. PerfectPaper is a careful first reader — not a replacement for a trusted human editor on your final pass."
          )}
        </p>
      </div>
    </section>
    """
  end

  # Default catalogue mirrors PerfectPaper.Billing.Prices
  # (Starter / Professional / Advanced). A free preview is available without a
  # subscription; the paid plans grant a number of full reviews per month.
  defp default_plans do
    [
      %{
        name: gettext("Starter"),
        price: "$40",
        cadence: "/mo",
        tagline: gettext("A careful read when you need a second opinion."),
        features: [
          gettext("1 full review per month"),
          gettext("Structured, sourced feedback on every section"),
          gettext("Comments you can address, dismiss, or undo"),
          gettext("Export to Word, Markdown, or HTML")
        ],
        cta: gettext("Choose Starter")
      },
      %{
        name: gettext("Professional"),
        price: "$100",
        cadence: "/mo",
        popular: true,
        tagline: gettext("For researchers revising toward a deadline."),
        features: [
          gettext("3 full reviews per month"),
          gettext("Re-read new drafts to catch issues you introduced while revising"),
          gettext("Methods, evidence, logic, and consistency checks"),
          gettext("Priority processing")
        ],
        cta: gettext("Choose Professional")
      },
      %{
        name: gettext("Advanced"),
        price: "$300",
        cadence: "/mo",
        tagline: gettext("For labs and authors with steady output."),
        features: [
          gettext("10 full reviews per month"),
          gettext("Team and organization support"),
          gettext("Custom review settings for your lab"),
          gettext("SSO, API access, and dedicated support")
        ],
        cta: gettext("Choose Advanced")
      }
    ]
  end
end
