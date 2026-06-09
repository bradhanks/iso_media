defmodule PerfectPaperWeb.Marketing.HeroComponents do
  @moduledoc """
  Hero sections and call-to-action blocks for PerfectPaper's marketing pages.

  PerfectPaper is an AI peer reviewer for academic papers — the voice here is
  measured, warm, and scholarly. These are pure, presentational function
  components built on daisyUI semantic classes and the `paper` theme. Headlines
  use `font-display` (Fraunces), reading copy uses `font-serif` (Newsreader),
  and UI/labels use `font-sans` (Outfit). Gold/accent is reserved for fills and
  hairlines — never as text on cream.

  Includes:

  - `seo_hero/1` — SEO/AEO-friendly landing hero with a lead, CTAs, and trust badges
  - `cta_section/1` — full-width closing call-to-action band
  """
  use Phoenix.Component
  use PerfectPaperWeb, :verified_routes
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders an SEO-optimized landing hero.

  The lead paragraph is intentionally front-loaded (within the first ~150
  characters) so answer engines and search snippets pick up a clean summary of
  what PerfectPaper does. Optional `badge` slots render a row of small trust
  signals beneath the actions.

  ## Example

      <.seo_hero
        eyebrow="AI peer review"
        title="A careful read for your paper, before the reviewers get it"
        lead="PerfectPaper reads your manuscript like a generous colleague — clear comments on argument, structure, and prose, returned in minutes."
        cta_text="Start a free read"
        cta_link={~p"/users/register"}
        secondary_cta_text="See how it works"
        secondary_cta_link="#how-it-works"
      >
        <:badge icon="hero-lock-closed" text="Your drafts are never used for training" />
        <:badge icon="hero-clock" text="Most papers reviewed in under five minutes" />
      </.seo_hero>
  """
  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :lead, :string, required: true
  attr :cta_text, :string, default: nil
  attr :cta_link, :string, required: true
  attr :secondary_cta_text, :string, default: nil
  attr :secondary_cta_link, :string, default: nil
  attr :class, :string, default: nil

  slot :badge, doc: "small trust signal row beneath the CTAs" do
    attr :icon, :string
    attr :text, :string
  end

  def seo_hero(assigns) do
    assigns = Map.update!(assigns, :cta_text, fn v -> v || gettext("Get started") end)

    ~H"""
    <section class={["relative overflow-hidden border-b border-base-content/10", @class]}>
      <div class="relative max-w-4xl mx-auto px-5 sm:px-6 lg:px-8 pt-28 pb-16 lg:pt-36 lg:pb-24 text-center">
        <div
          :if={@eyebrow}
          class="ds-eyebrow flex items-center justify-center gap-3 text-base-content/60 mb-8"
        >
          <span class="inline-block h-px w-8 bg-accent"></span>
          <span>{@eyebrow}</span>
          <span class="inline-block h-px w-8 bg-accent"></span>
        </div>

        <h1 class="font-display font-semibold tracking-[-0.02em] leading-[1.05] text-4xl sm:text-5xl lg:text-6xl text-base-content">
          {@title}
        </h1>

        <p class="mt-8 max-w-2xl mx-auto font-serif text-lg lg:text-xl text-base-content/75 leading-relaxed">
          {@lead}
        </p>

        <div class="mt-10 flex flex-col sm:flex-row items-center justify-center gap-4">
          <.link navigate={@cta_link} class="btn btn-primary btn-lg font-sans font-semibold gap-2">
            {@cta_text}
            <.icon name="hero-arrow-right" class="size-5" />
          </.link>
          <.link
            :if={@secondary_cta_text && @secondary_cta_link}
            navigate={@secondary_cta_link}
            class="btn btn-outline btn-lg font-sans font-semibold"
          >
            {@secondary_cta_text}
          </.link>
        </div>

        <div
          :if={@badge != []}
          class="mt-10 flex flex-wrap items-center justify-center gap-x-8 gap-y-3 font-sans text-sm text-base-content/60"
        >
          <div :for={badge <- @badge} class="flex items-center gap-2">
            <.icon :if={badge[:icon]} name={badge[:icon]} class="size-4 text-accent" />
            {badge[:text]}
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders a full-width closing call-to-action band on the primary surface.

  Used at the foot of marketing pages to convert. Supports a primary navigate
  action, an optional secondary `href` action (e.g. a mailto), and a row of
  reassurance `badge` slots.

  ## Example

      <.cta_section
        title="Give your next paper a careful read"
        subtitle="Join researchers who run PerfectPaper before every submission."
        primary_text="Start free"
        primary_link={~p"/users/register"}
        secondary_text="Talk to us"
        secondary_link="mailto:hello@perfectpaper.ink"
      >
        <:badge icon="hero-check" text="No card required" />
        <:badge icon="hero-academic-cap" text="Built for academic writing" />
      </.cta_section>
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :primary_text, :string, required: true
  attr :primary_link, :string, required: true
  attr :secondary_text, :string, default: nil
  attr :secondary_link, :string, default: nil
  attr :class, :string, default: nil

  slot :badge do
    attr :icon, :string
    attr :text, :string
  end

  def cta_section(assigns) do
    ~H"""
    <section class={["bg-primary text-primary-content py-20 lg:py-28", @class]}>
      <div class="max-w-4xl mx-auto px-5 sm:px-6 lg:px-8 text-center">
        <h2 class="font-display font-semibold tracking-[-0.01em] text-3xl md:text-4xl lg:text-5xl">
          {@title}
        </h2>
        <p
          :if={@subtitle}
          class="mt-5 max-w-2xl mx-auto font-serif text-lg text-primary-content/80 leading-relaxed"
        >
          {@subtitle}
        </p>

        <div class="mt-10 flex flex-col sm:flex-row items-center justify-center gap-4">
          <.link
            navigate={@primary_link}
            class="btn btn-lg font-sans font-semibold bg-base-100 text-primary border-base-100 hover:bg-base-200 gap-2"
          >
            {@primary_text}
            <.icon name="hero-arrow-right" class="size-5" />
          </.link>
          <a
            :if={@secondary_text && @secondary_link}
            href={@secondary_link}
            class="btn btn-lg btn-outline font-sans font-semibold border-primary-content text-primary-content hover:bg-primary-content hover:text-primary"
          >
            {@secondary_text}
          </a>
        </div>

        <div
          :if={@badge != []}
          class="mt-8 flex flex-wrap items-center justify-center gap-x-8 gap-y-3 font-sans text-sm text-primary-content/75"
        >
          <div :for={badge <- @badge} class="flex items-center gap-2">
            <.icon :if={badge[:icon]} name={badge[:icon]} class="size-4" />
            {badge[:text]}
          </div>
        </div>
      </div>
    </section>
    """
  end
end
