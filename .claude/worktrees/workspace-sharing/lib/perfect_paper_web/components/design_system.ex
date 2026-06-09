defmodule PerfectPaperWeb.DesignSystem do
  @moduledoc """
  Brand ("Paper") design-system components, converted from the daisyUI preview
  mockups in `docs/design/mockups/preview`.

  These are thin, themeable function components built on daisyUI semantic
  classes — colors resolve from the active `data-theme` (default `paper`), so the
  same markup re-skins for free. Names here intentionally avoid clashing with
  `PerfectPaperWeb.CoreComponents` (which already provides `button/1`, `input/1`,
  `flash/1`, `icon/1`, `table/1`, etc.).

  Reading vs. operating: long-form text uses the serif faces (`font-serif` /
  `font-display`); controls and labels use `font-sans` (Outfit).
  """
  use Phoenix.Component

  @doc """
  The PerfectPaper logo. Renders one of the self-hosted SVG lockups from
  `priv/static/images`.

  ## Examples

      <.logo />
      <.logo variant="icon" class="h-8" />
  """
  attr :variant, :string,
    default: "full",
    values: ~w(full icon wordmark mark),
    doc: "which lockup to render"

  attr :class, :string, default: "h-8 w-auto"
  attr :rest, :global

  def logo(assigns) do
    src =
      case assigns.variant do
        "full" -> "/images/logo.svg"
        "icon" -> "/images/icon-mulberry.svg"
        "wordmark" -> "/images/wordmark.svg"
        "mark" -> "/images/icon-mulberry.png"
      end

    assigns = assign(assigns, :src, src)

    ~H"""
    <img src={@src} alt="PerfectPaper" class={@class} {@rest} />
    """
  end

  @doc """
  A content card (figure optional via the `figure` slot, actions via `actions`).

      <.card title="Weekly digest">
        A card groups related content.
        <:actions><button class="btn btn-primary btn-sm">Read</button></:actions>
      </.card>
  """
  attr :title, :string, default: nil
  attr :class, :string, default: "w-72 bg-base-100 shadow-sm"
  attr :rest, :global
  slot :figure
  slot :inner_block, required: true
  slot :actions

  def card(assigns) do
    ~H"""
    <div class={["card", @class]} {@rest}>
      <figure :if={@figure != []}>{render_slot(@figure)}</figure>
      <div class="card-body">
        <h2 :if={@title} class="card-title font-display">{@title}</h2>
        <div class="text-sm text-base-content/70 font-serif">{render_slot(@inner_block)}</div>
        <div :if={@actions != []} class="card-actions justify-end">{render_slot(@actions)}</div>
      </div>
    </div>
    """
  end

  @doc """
  A status badge.

      <.badge color="primary">New</.badge>
      <.badge color="success" variant="soft" size="sm">Paid</.badge>
  """
  attr :color, :string,
    default: "primary",
    values: ~w(neutral primary secondary accent info success warning error ghost)

  attr :variant, :string, default: "solid", values: ~w(solid outline soft dash ghost)
  attr :size, :string, default: nil, doc: "xs | sm | md | lg"
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "badge",
        @color != "ghost" && "badge-#{@color}",
        @variant != "solid" && "badge-#{@variant}",
        @size && "badge-#{@size}",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  An inline alert.

      <.alert color="success" variant="soft">Your changes have been saved.</.alert>
  """
  attr :color, :string, default: "info", values: ~w(info success warning error)
  attr :variant, :string, default: "solid", values: ~w(solid soft outline)
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def alert(assigns) do
    ~H"""
    <div
      role="alert"
      class={[
        "alert alert-#{@color}",
        @variant != "solid" && "alert-#{@variant}",
        @class
      ]}
      {@rest}
    >
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc """
  A horizontal tab bar. Pass `tabs` items; mark one `active`.

      <.tabs tabs={[%{label: "Overview"}, %{label: "Activity", active: true}]} />
  """
  attr :tabs, :list, required: true, doc: "list of %{label:, active?:}"
  attr :class, :string, default: "tabs-box w-fit"
  attr :rest, :global

  def tabs(assigns) do
    ~H"""
    <div role="tablist" class={["tabs", @class]} {@rest}>
      <a
        :for={tab <- @tabs}
        role="tab"
        class={["tab", Map.get(tab, :active) && "tab-active"]}
      >
        {tab.label}
      </a>
    </div>
    """
  end

  @doc """
  A menu (vertical by default; pass `direction="horizontal"`).

      <.menu items={[%{label: "Inbox", active: true}, %{label: "Sent"}]} />
  """
  attr :items, :list, required: true
  attr :direction, :string, default: "vertical", values: ~w(vertical horizontal)
  attr :class, :string, default: "bg-base-200 rounded-box w-fit"
  attr :rest, :global

  def menu(assigns) do
    ~H"""
    <ul
      class={[
        "menu",
        @direction == "horizontal" && "menu-horizontal",
        @class
      ]}
      {@rest}
    >
      <li :for={item <- @items}>
        <a class={Map.get(item, :active) && "menu-active"}>{item.label}</a>
      </li>
    </ul>
    """
  end

  @doc """
  A single proofreading-feedback card — the core review unit (see the FEEDBACK
  pane in the app mockup). Quotes the manuscript, explains the issue, and offers
  done / dismiss / chat actions via the `actions` slot.

      <.feedback_card number="1" title="Causal adjustment underspecified in §3.2"
        quote="As shown in Figure 2, directed acyclic graphs…">
        The causal framing needs the estimands and adjustment sets stated.
        <:actions>…</:actions>
      </.feedback_card>
  """
  attr :number, :string, default: nil, doc: "comment number, e.g. \"1\""
  attr :title, :string, required: true
  attr :quote, :string, default: nil, doc: "the quoted manuscript passage"
  attr :status, :string, default: "open", values: ~w(open done dismissed)
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true, doc: "the explanation body"
  slot :actions

  def feedback_card(assigns) do
    ~H"""
    <article
      class={[
        "rounded-box border border-base-300 bg-base-100 p-5 mb-3.5 transition",
        @status == "done" && "border-success/45 bg-success/5",
        @class
      ]}
      {@rest}
    >
      <h3 class="font-display font-semibold text-base leading-snug mb-2.5">
        <span :if={@number} class="text-primary font-bold mr-0.5">#{@number}</span>
        {@title}
      </h3>

      <figure :if={@quote} class="flex gap-2.5 rounded-box bg-base-200/60 px-4 py-3 my-3">
        <.icon_quote class="size-4 shrink-0 text-primary/55 mt-0.5" />
        <blockquote class="font-serif italic text-sm leading-relaxed text-base-content/80 m-0">
          {@quote}
        </blockquote>
      </figure>

      <div class="font-serif text-sm leading-relaxed text-base-content/80">
        {render_slot(@inner_block)}
      </div>

      <div :if={@actions != []} class="flex items-center gap-2 mt-3.5">
        {render_slot(@actions)}
      </div>
    </article>
    """
  end

  @doc """
  A loading indicator. `kind` is one of daisyUI's loading styles.

      <.loading kind="dots" />
  """
  attr :kind, :string, default: "spinner", values: ~w(spinner dots ring ball bars infinity)
  attr :size, :string, default: "md", values: ~w(xs sm md lg)
  attr :class, :string, default: "text-primary"
  attr :rest, :global

  def loading(assigns) do
    ~H"""
    <span class={["loading loading-#{@kind} loading-#{@size}", @class]} {@rest}></span>
    """
  end

  # Small inline quotation-mark glyph used by feedback_card (kept local so the
  # component has no external icon dependency).
  @doc false
  attr :class, :string, default: nil

  def icon_quote(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M7 7h4v4H8v3H5V9a2 2 0 012-2zm9 0h4v4h-3v3h-3V9a2 2 0 012-2z" />
    </svg>
    """
  end
end
