defmodule PerfectPaperWeb.Marketing.ContentComponents do
  @moduledoc """
  Content-block components for PerfectPaper's marketing pages — feature
  columns, stats, testimonials, FAQs, how-it-works steps, and a "trusted by"
  strip.

  PerfectPaper is an AI peer reviewer for academic papers; copy here stays
  measured, warm, and scholarly. Pure, presentational function components on
  daisyUI semantic classes and the `paper` theme. Section headings use
  `font-display` (Fraunces), reading copy uses `font-serif` (Newsreader), and
  labels/metrics use `font-sans` (Outfit). Gold/accent is reserved for fills
  and icons — never as text on cream.

  Includes:

  - `section_title/1` — centered display heading with optional eyebrow and subtitle
  - `feature_columns/1` — grid of feature cards with iconography
  - `stats_bar/1` — horizontal row of headline metrics
  - `testimonial_grid/1` — grid of researcher testimonials
  - `faq_section/1` — accordion of frequently asked questions
  - `step_list/1` — numbered "how it works" steps
  - `trusted_by_section/1` — institution / logo-cloud strip
  """
  use Phoenix.Component
  use PerfectPaperWeb, :verified_routes
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders a centered section heading with an optional eyebrow and subtitle.

  ## Example

      <.section_title
        eyebrow="How it works"
        title="From draft to feedback in three steps"
        subtitle="No setup, no formatting rules to learn — just upload and read."
      />
  """
  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil

  def section_title(assigns) do
    ~H"""
    <div class={["text-center max-w-2xl mx-auto", @class]}>
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
    """
  end

  @doc """
  Renders a grid of feature cards. Each `feature` slot takes an icon and title.

  ## Example

      <.feature_columns
        title="A reviewer in your corner"
        subtitle="Every comment is specific, actionable, and kind."
      >
        <:feature icon="hero-chat-bubble-bottom-center-text" title="Clear comments">
          Margin notes you can act on, not vague rewrites.
        </:feature>
        <:feature icon="hero-rectangle-group" title="Structure review">
          Flags gaps in your argument and the order of your sections.
        </:feature>
        <:feature icon="hero-book-open" title="Citation hints">
          Catches missing references and inconsistent formats.
        </:feature>
      </.feature_columns>
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil

  slot :feature, required: true do
    attr :icon, :string, required: true
    attr :title, :string, required: true
  end

  def feature_columns(assigns) do
    ~H"""
    <section class={["bg-base-100 py-20 lg:py-28", @class]}>
      <div class="ds-container">
        <.section_title title={@title} subtitle={@subtitle} class="mb-16" />

        <div class="grid md:grid-cols-2 lg:grid-cols-3 gap-6 lg:gap-8">
          <div
            :for={feature <- @feature}
            class="group bg-base-100 border border-base-content/10 p-7 transition-colors hover:border-primary/40"
          >
            <span class="inline-flex items-center justify-center size-11 rounded-sm bg-base-200 text-base-content group-hover:bg-primary/10 group-hover:text-primary transition-colors mb-5">
              <.icon name={feature.icon} class="size-5" />
            </span>
            <h3 class="font-display text-xl font-semibold tracking-tight text-base-content">
              {feature.title}
            </h3>
            <p class="mt-3 font-serif text-base-content/70 leading-relaxed">
              {render_slot(feature)}
            </p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders a horizontal bar of headline metrics.

  ## Example

      <.stats_bar>
        <:stat value="120k+" label="Manuscripts reviewed" />
        <:stat value="4 min" label="Average turnaround" />
        <:stat value="98%" label="Of comments rated helpful" />
        <:stat value="0" label="Drafts used for training" />
      </.stats_bar>
  """
  attr :class, :string, default: nil

  slot :stat, required: true do
    attr :value, :string, required: true
    attr :label, :string, required: true
  end

  def stats_bar(assigns) do
    ~H"""
    <section class={["bg-base-100", @class]}>
      <div class="ds-container">
        <div class="grid grid-cols-2 md:grid-cols-4 border-y border-base-content/10">
          <div
            :for={{stat, idx} <- Enum.with_index(@stat)}
            class={[
              "p-6 lg:p-8",
              idx != 0 && "md:border-l border-base-content/10",
              idx >= 2 && "border-t md:border-t-0 border-base-content/10"
            ]}
          >
            <div class="font-display text-3xl lg:text-4xl font-semibold tracking-tight text-base-content leading-none">
              {stat.value}
            </div>
            <div class="mt-3 font-sans text-sm text-base-content/60 leading-snug">
              {stat.label}
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders a grid of researcher testimonials with attribution.

  ## Example

      <.testimonial_grid
        title="What researchers say"
        subtitle="From first-year PhDs to lab directors."
      >
        <:testimonial name="Dr. Amara Okafor" affiliation="Postdoc, molecular biology" initials="AO">
          It caught a gap in my methods section my own co-authors had missed.
        </:testimonial>
      </.testimonial_grid>
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil

  slot :testimonial, required: true do
    attr :name, :string, required: true
    attr :affiliation, :string, required: true
    attr :initials, :string, required: true
  end

  def testimonial_grid(assigns) do
    ~H"""
    <section class={["bg-base-200/40 py-20 lg:py-28", @class]}>
      <div class="ds-container">
        <.section_title title={@title} subtitle={@subtitle} class="mb-16" />

        <div class="grid md:grid-cols-2 lg:grid-cols-3 gap-6 lg:gap-8">
          <figure
            :for={testimonial <- @testimonial}
            class="flex flex-col bg-base-100 border border-base-content/10 p-7"
          >
            <blockquote class="font-serif italic text-base-content/85 leading-relaxed flex-1">
              "{render_slot(testimonial)}"
            </blockquote>
            <figcaption class="flex items-center gap-3.5 mt-6 pt-5 border-t border-base-content/10">
              <span class="inline-flex items-center justify-center size-10 rounded-full bg-primary/10 text-primary font-sans font-semibold text-sm">
                {testimonial.initials}
              </span>
              <span>
                <span class="block font-sans font-semibold text-sm text-base-content">
                  {testimonial.name}
                </span>
                <span class="block font-sans text-xs text-base-content/55">
                  {testimonial.affiliation}
                </span>
              </span>
            </figcaption>
          </figure>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders an accordion of frequently asked questions. The first item is open by
  default. Each `item` slot takes a `question`.

  ## Example

      <.faq_section title="Questions, answered">
        <:item question="Do you use my drafts to train models?">
          Never. Your manuscripts are yours, and they are not used for training.
        </:item>
      </.faq_section>
  """
  attr :title, :string, required: true
  attr :class, :string, default: nil

  slot :item, required: true do
    attr :question, :string, required: true
  end

  def faq_section(assigns) do
    ~H"""
    <section class={["bg-base-100 py-20 lg:py-28", @class]}>
      <div class="max-w-3xl mx-auto px-5 sm:px-6 lg:px-8">
        <.section_title title={@title} class="mb-12" />

        <div class="join join-vertical w-full">
          <div
            :for={{item, idx} <- Enum.with_index(@item)}
            class="collapse collapse-arrow join-item border border-base-content/10"
          >
            <input type="radio" name="faq-accordion" checked={idx == 0} />
            <div class="collapse-title font-display text-lg font-semibold text-base-content">
              {item.question}
            </div>
            <div class="collapse-content">
              <p class="font-serif text-base-content/70 leading-relaxed">{render_slot(item)}</p>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders a numbered "how it works" step list. Mark a step `done` to render a
  check instead of its number.

  ## Example

      <.step_list>
        <:step number={1} title="Upload your draft">
          Drop in a Word file (.docx) — no formatting rules to learn.
        </:step>
        <:step number={2} title="Get a careful read">
          PerfectPaper returns specific comments in minutes.
        </:step>
        <:step number={3} title="Act on each note">
          Address, dismiss, or undo every comment as you revise.
        </:step>
      </.step_list>
  """
  attr :class, :string, default: nil

  slot :step, required: true do
    attr :number, :integer, required: true
    attr :title, :string, required: true
    attr :done, :boolean
  end

  def step_list(assigns) do
    ~H"""
    <ol class={["space-y-8", @class]}>
      <li :for={step <- @step} class="flex gap-5">
        <div class="shrink-0">
          <span
            :if={!step[:done]}
            class="flex size-10 items-center justify-center rounded-full bg-primary text-primary-content font-sans font-semibold"
          >
            {step.number}
          </span>
          <span
            :if={step[:done]}
            class="flex size-10 items-center justify-center rounded-full bg-success text-success-content"
          >
            <.icon name="hero-check" class="size-5" />
          </span>
        </div>
        <div>
          <h3 class="font-display text-lg font-semibold tracking-tight text-base-content">
            {step.title}
          </h3>
          <p class="mt-1.5 font-serif text-base-content/70 leading-relaxed">
            {render_slot(step)}
          </p>
        </div>
      </li>
    </ol>
    """
  end

  @doc """
  Renders a quiet "trusted by" strip — a row of institution wordmarks rendered
  as understated text.

  ## Example

      <.trusted_by_section>
        <:logo name="Stanford" />
        <:logo name="MIT" />
        <:logo name="Max Planck" />
        <:logo name="ETH Zürich" />
      </.trusted_by_section>
  """
  attr :title, :string, default: nil
  attr :class, :string, default: nil

  slot :logo, required: true do
    attr :name, :string, required: true
  end

  def trusted_by_section(assigns) do
    assigns =
      Map.update!(assigns, :title, fn v ->
        v || gettext("Used by researchers at institutions worldwide")
      end)

    ~H"""
    <section class={["bg-base-200/40 py-12 border-y border-base-content/10", @class]}>
      <div class="ds-container">
        <p class="text-center font-sans text-[0.68rem] uppercase tracking-[0.2em] text-base-content/55 mb-8">
          {@title}
        </p>
        <div class="flex flex-wrap items-center justify-center gap-x-12 gap-y-6">
          <span
            :for={logo <- @logo}
            class="font-display text-xl lg:text-2xl font-semibold text-base-content/30"
          >
            {logo.name}
          </span>
        </div>
      </div>
    </section>
    """
  end
end
