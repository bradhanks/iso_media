defmodule PerfectPaperWeb.Marketing.EditorialComponents do
  @moduledoc """
  Editorial-style primitives for PerfectPaper's narrative, policy, and long-form
  pages — about, manifesto, privacy, terms, and the like.

  Design aesthetic: a quiet, manuscript-like editorial voice. Chapter-numbered
  sections, a document-record masthead, plain-language "in brief" callouts, and
  a display serif italic accent. Headlines and accents use `font-display`
  (Fraunces); body reading copy uses `font-serif` (Newsreader); metadata and
  labels use `font-sans` (Outfit). Gold/accent is used for fills and hairlines
  only — never as text on cream.

  Pure, presentational function components built on daisyUI semantic classes and
  the `paper` theme.

  Includes:

  - `document_record/1` — masthead strip for legal/policy pages
  - `chapter_section/1` — numbered section with optional "in brief" callout
  - `sticky_toc/1` — responsive (collapsible + sticky) table of contents with scroll-spy
  - `back_to_top/1` — floating back-to-top control for long pages
  - `editorial_hero/1` — display hero with a serif italic accent word
  - `stat_strip/1` — numbered horizontal stat row
  - `editorial_table/1` — data-dense table with mono-caps headers
  - `routing_card/1` — large clickable intent-routing card
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders the document-record masthead at the top of a legal or policy page —
  version, effective date, document kind, and a plain-language summary.

  ## Example

      <.document_record
        kind="Privacy Notice"
        version="v2.0"
        effective="May 30, 2026"
        reading_minutes={6}
        summary="We collect only what's needed to give you a careful read. Your drafts are never used to train models."
        jurisdiction="Global · GDPR · CCPA"
      />
  """
  attr :kind, :string, required: true
  attr :version, :string, required: true
  attr :effective, :string, required: true
  attr :reading_minutes, :integer, default: nil
  attr :summary, :string, required: true
  attr :jurisdiction, :string, default: "Global · GDPR · CCPA"

  def document_record(assigns) do
    ~H"""
    <div class="relative border-b border-base-content/10">
      <div class="ds-container relative pt-28 pb-12 lg:pt-36 lg:pb-16">
        <div class="flex flex-col lg:flex-row lg:items-end lg:justify-between gap-8">
          <div class="max-w-3xl">
            <div class="flex items-center gap-3 font-sans text-[0.68rem] uppercase tracking-[0.2em] text-base-content/60">
              <span class="inline-block h-px w-8 bg-accent"></span>
              <span>{gettext("Document of record")}</span>
              <span class="text-primary">§</span>
              <span>{@kind}</span>
            </div>
            <h1 class="mt-6 font-display font-semibold tracking-[-0.02em] leading-[1.02] text-5xl sm:text-6xl lg:text-7xl text-base-content">
              {@kind}.<br />
              <span class="font-serif italic font-normal text-base-content/55">
                {gettext("In plain language.")}
              </span>
            </h1>
            <p class="mt-8 max-w-2xl font-serif text-lg text-base-content/75 leading-relaxed">
              {@summary}
            </p>
          </div>

          <dl class="shrink-0 grid grid-cols-2 gap-x-10 gap-y-5 font-sans text-xs uppercase tracking-[0.14em] border-l border-base-content/10 pl-8">
            <div>
              <dt class="text-base-content/45">{gettext("Version")}</dt>
              <dd class="mt-1 text-base-content font-semibold">{@version}</dd>
            </div>
            <div>
              <dt class="text-base-content/45">{gettext("Effective")}</dt>
              <dd class="mt-1 text-base-content font-semibold">{@effective}</dd>
            </div>
            <div>
              <dt class="text-base-content/45">{gettext("Jurisdiction")}</dt>
              <dd class="mt-1 text-base-content font-semibold normal-case tracking-normal">
                {@jurisdiction}
              </dd>
            </div>
            <div :if={@reading_minutes}>
              <dt class="text-base-content/45">{gettext("Reading")}</dt>
              <dd class="mt-1 text-base-content font-semibold">≈ {@reading_minutes} min</dd>
            </div>
          </dl>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a numbered chapter/section with an optional plain-language "in brief"
  callout above the dense body content.

  ## Example

      <.chapter_section number="01" title="What we collect" id="collection">
        <:brief>
          Your account email, the documents you upload, and the feedback we generate. Nothing more.
        </:brief>
        <p>Detailed language here…</p>
      </.chapter_section>
  """
  attr :number, :string, required: true
  attr :title, :string, required: true
  attr :id, :string, required: true

  slot :brief, doc: "plain-language summary above the dense body"
  slot :inner_block, required: true

  def chapter_section(assigns) do
    ~H"""
    <section
      id={@id}
      class="scroll-mt-28 py-12 lg:py-16 border-b border-base-content/10 last:border-b-0"
    >
      <div class="grid lg:grid-cols-12 gap-8 lg:gap-12">
        <div class="lg:col-span-3">
          <div class="font-display font-normal italic text-7xl lg:text-8xl leading-none text-base-content/15">
            §{@number}
          </div>
          <h2 class="mt-4 font-display text-2xl lg:text-3xl font-semibold tracking-tight text-base-content">
            {@title}
          </h2>
        </div>

        <div class="lg:col-span-9 space-y-6">
          <aside
            :if={@brief != []}
            class="relative border-l-2 border-accent bg-accent/[0.06] pl-5 py-4 pr-4"
          >
            <div class="font-sans text-[0.68rem] uppercase tracking-[0.2em] text-primary font-semibold mb-1.5">
              {gettext("In brief")}
            </div>
            <div class="font-serif text-base-content/85 text-[0.98rem] leading-relaxed">
              {render_slot(@brief)}
            </div>
          </aside>

          <div class="font-serif text-base-content/80 leading-relaxed space-y-4">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders the table of contents for a long policy page. Responsive by design:

    * on mobile it collapses into a daisyUI disclosure (`<details class="collapse">`)
      that sits above the body, so small screens keep navigation Refine's page drops;
    * on `lg` and up it becomes a sticky sidebar rail with a left-border active marker.

  Both surfaces carry `data-toc-spy`/`data-toc-link` so the `legal_toc.js` scroll-spy
  highlights the current section in either one (it toggles `aria-current="true"`, which
  the `aria-[current=true]:` Tailwind variants style). Pair with `back_to_top/1`.

  ## Example

      <.sticky_toc items={[
        {"overview", "Overview", "01"},
        {"collection", "What we collect", "02"}
      ]} />
  """
  attr :items, :list, required: true, doc: "list of {id, label, number} tuples"

  def sticky_toc(assigns) do
    ~H"""
    <%!-- Mobile: collapsible disclosure above the body --%>
    <details
      class="collapse collapse-arrow border border-base-content/10 bg-base-100 rounded-sm mb-10 lg:hidden"
      data-toc-spy
    >
      <summary class="collapse-title font-sans text-[0.68rem] uppercase tracking-[0.2em] text-base-content/60 font-semibold">
        {gettext("Contents")}
      </summary>
      <div class="collapse-content">
        <.toc_links items={@items} />
      </div>
    </details>

    <%!-- Desktop: sticky sidebar rail --%>
    <nav class="hidden lg:block" aria-label={gettext("Document contents")} data-toc-spy>
      <div class="sticky top-24">
        <div class="font-sans text-[0.68rem] uppercase tracking-[0.2em] text-base-content/50 mb-4 pb-3 border-b border-base-content/10">
          {gettext("Contents")}
        </div>
        <.toc_links items={@items} />
      </div>
    </nav>
    """
  end

  attr :items, :list, required: true

  defp toc_links(assigns) do
    ~H"""
    <ol class="space-y-0.5">
      <li :for={{id, label, number} <- @items}>
        <a
          href={"##{id}"}
          data-toc-link
          class={[
            "group flex items-baseline gap-3 border-l-2 border-transparent pl-3 pr-2 py-1.5",
            "font-sans text-sm leading-snug text-base-content/60 transition-colors hover:text-primary",
            "aria-[current=true]:border-primary aria-[current=true]:bg-primary/[0.07]",
            "aria-[current=true]:text-primary aria-[current=true]:font-medium"
          ]}
        >
          <span class="font-mono text-[0.7rem] text-base-content/35 w-5 shrink-0 pt-px transition-colors group-hover:text-primary group-aria-[current=true]:text-primary">
            {number}
          </span>
          <span class="min-w-0">{label}</span>
        </a>
      </li>
    </ol>
    """
  end

  @doc """
  Renders a floating "back to top" control for long pages. Hidden until the
  reader scrolls down; `legal_toc.js` toggles the `hidden` attribute on scroll
  and smooth-scrolls to the top on click. Built on the daisyUI `fab` placement.

  ## Example

      <.back_to_top />
  """
  def back_to_top(assigns) do
    ~H"""
    <div class="fab transition-opacity duration-300" data-back-to-top hidden>
      <button
        type="button"
        class="btn btn-circle btn-lg btn-primary shadow-lg"
        aria-label={gettext("Back to top")}
      >
        <.icon name="hero-arrow-up" class="size-5" />
      </button>
    </div>
    """
  end

  @doc """
  Renders an editorial hero with a display serif italic accent word and an
  optional eyebrow and actions.

  ## Example

      <.editorial_hero eyebrow="About" title="Built to make peer review" accent="kinder" suffix="and faster.">
        We think every researcher deserves a careful, generous read long before a journal's.
        <:actions>
          <a href="#story" class="btn btn-primary font-sans font-semibold">Read our story</a>
        </:actions>
      </.editorial_hero>
  """
  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :accent, :string, required: true
  attr :suffix, :string, default: ""
  slot :inner_block
  slot :actions

  def editorial_hero(assigns) do
    ~H"""
    <section class="relative overflow-hidden border-b border-base-content/10">
      <div class="ds-container relative pt-28 pb-16 lg:pt-36 lg:pb-24">
        <div class="max-w-4xl">
          <div
            :if={@eyebrow}
            class="flex items-center gap-3 font-sans text-[0.68rem] uppercase tracking-[0.2em] text-base-content/60 mb-8"
          >
            <span class="inline-block h-px w-10 bg-accent"></span>
            <span>{@eyebrow}</span>
          </div>
          <h1 class="font-display font-semibold tracking-[-0.02em] leading-[1.0] text-5xl sm:text-7xl lg:text-[6rem] text-base-content">
            {@title}
            <span class="font-serif italic font-normal text-primary">
              {@accent}
            </span>
            <span :if={@suffix != ""}>{@suffix}</span>
          </h1>
          <div
            :if={@inner_block != []}
            class="mt-10 max-w-2xl font-serif text-lg lg:text-xl text-base-content/75 leading-relaxed"
          >
            {render_slot(@inner_block)}
          </div>
          <div :if={@actions != []} class="mt-10 flex flex-wrap items-center gap-4">
            {render_slot(@actions)}
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  Renders a numbered horizontal stat strip — editorial trust signals and metrics.

  ## Example

      <.stat_strip items={[
        %{value: "120k+", label: "Manuscripts reviewed"},
        %{value: "4 min", label: "Average turnaround"},
        %{value: "AES-256", label: "Encryption at rest", mono: true},
        %{value: "0", label: "Drafts used for training"}
      ]} />
  """
  attr :items, :list, required: true

  def stat_strip(assigns) do
    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 border-y border-base-content/10">
      <div
        :for={{item, idx} <- Enum.with_index(@items)}
        class={[
          "relative p-6 lg:p-8",
          idx != 0 && "md:border-l border-base-content/10",
          idx >= 2 && "md:border-t-0 border-t border-base-content/10"
        ]}
      >
        <div class="font-sans text-[0.68rem] uppercase tracking-[0.2em] text-base-content/45 mb-3">
          §{String.pad_leading(to_string(idx + 1), 2, "0")}
        </div>
        <div class={[
          "font-display text-3xl lg:text-4xl font-semibold tracking-tight text-base-content leading-none",
          Map.get(item, :mono) && "font-mono text-xl lg:text-2xl tracking-tight"
        ]}>
          {item.value}
        </div>
        <div class="mt-3 font-sans text-sm text-base-content/60 leading-snug">
          {item.label}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a data-dense editorial table with mono-caps headers, generous row
  padding, and hairline borders. Intended for use inside `chapter_section/1`
  blocks; uses `not-prose` to escape Tailwind Typography defaults.

  The first cell in each row is emphasized unless `first_col_plain` is set.

  ## Example

      <.editorial_table columns={["Artifact", "Where it lives", "Retention"]}>
        <tr>
          <td>Uploaded drafts</td>
          <td>Encrypted blob storage</td>
          <td>Deleted on request, or 90 days after account closure</td>
        </tr>
      </.editorial_table>
  """
  attr :columns, :list, required: true
  attr :caption, :string, default: nil
  attr :first_col_plain, :boolean, default: false
  attr :class, :string, default: nil
  slot :inner_block, required: true, doc: "<tr><td>…</td></tr> rows"

  def editorial_table(assigns) do
    ~H"""
    <div class={[
      "not-prose my-8 overflow-x-auto border border-base-content/10 bg-base-100 rounded-sm",
      @class
    ]}>
      <table class="table w-full">
        <caption
          :if={@caption}
          class="px-6 pt-5 pb-0 text-left font-sans text-[0.62rem] uppercase tracking-[0.22em] text-base-content/45"
        >
          {@caption}
        </caption>
        <thead>
          <tr class="bg-base-200/55 border-b border-base-content/10">
            <th
              :for={col <- @columns}
              class="text-left px-6 py-4 font-sans text-[0.68rem] uppercase tracking-[0.22em] text-base-content/55 font-semibold leading-snug whitespace-nowrap"
            >
              {col}
            </th>
          </tr>
        </thead>
        <tbody class={[
          "divide-y divide-base-content/10 font-serif",
          "[&_tr]:transition-colors [&_tr]:hover:bg-base-200/35",
          "[&_td]:px-6 [&_td]:py-5 [&_td]:text-[0.9rem] [&_td]:leading-[1.65] [&_td]:align-top [&_td]:text-base-content/75",
          !@first_col_plain && "[&_td:first-child]:font-semibold [&_td:first-child]:text-base-content",
          "[&_td_code]:font-mono [&_td_code]:text-[0.8rem] [&_td_code]:bg-base-200 [&_td_code]:text-base-content [&_td_code]:px-1.5 [&_td_code]:py-0.5 [&_td_code]:rounded-sm"
        ]}>
          {render_slot(@inner_block)}
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a large, clickable routing card used on contact and support hubs to
  route people by intent. Icon + eyebrow + title + description + arrow.

  ## Example

      <.routing_card
        href="mailto:hello@perfectpaper.ink"
        icon="hero-chat-bubble-left-right"
        eyebrow="Talk to us"
        title="Questions about your account"
        description="Billing, plans, or anything else — we usually reply within a day."
      />
  """
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :external, :boolean, default: false

  def routing_card(assigns) do
    ~H"""
    <a
      href={@href}
      target={if @external, do: "_blank", else: nil}
      rel={if @external, do: "noopener noreferrer", else: nil}
      class="group relative block p-8 bg-base-100 border border-base-content/10 hover:border-primary transition-all duration-300 hover:shadow-md"
    >
      <div class="flex items-start justify-between mb-10">
        <span class="inline-flex items-center justify-center size-11 rounded-sm bg-base-200 text-base-content group-hover:bg-primary/10 group-hover:text-primary transition-colors">
          <.icon name={@icon} class="size-5" />
        </span>
        <.icon
          name="hero-arrow-up-right"
          class="size-5 text-base-content/30 group-hover:text-primary group-hover:-translate-y-0.5 group-hover:translate-x-0.5 transition-all"
        />
      </div>
      <div class="font-sans text-[0.68rem] uppercase tracking-[0.2em] text-base-content/50 mb-2">
        {@eyebrow}
      </div>
      <div class="font-display text-xl font-semibold text-base-content tracking-tight">
        {@title}
      </div>
      <div class="mt-3 font-serif text-sm text-base-content/65 leading-relaxed">
        {@description}
      </div>
    </a>
    """
  end
end
