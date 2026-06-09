defmodule PerfectPaperWeb.DaisyDataDisplayComponents do
  @moduledoc """
  DaisyUI Data Display Components.

  Provides data display components following DaisyUI's component structure:
  - Avatar (user images/placeholders)
  - Badge (labels/tags)
  - Card (content containers) - Note: also in ContainerComponents
  - Stat (statistics display)
  - Kbd (keyboard key indicators)
  - Countdown (animated countdown)
  - Collapse/Accordion (expandable content)
  - Chat (chat bubbles)
  - Timeline (event timeline)
  - Diff (content comparison)
  - Table (data tables) - Note: also in CoreComponents

  See https://daisyui.com/components/ for reference.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  # =============================================================================
  # AVATAR
  # =============================================================================

  @doc """
  Renders an avatar.

  ## Examples

      <.avatar src="/images/user.jpg" />
      <.avatar src="/images/user.jpg" size={:lg} online />
      <.avatar placeholder="JD" />
      <.avatar placeholder="AB" size={:sm} ring ring_color={:primary} />

  """
  attr :src, :string, default: nil, doc: "image source URL"
  attr :placeholder, :string, default: nil, doc: "placeholder text (initials)"
  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg, :xl], doc: "avatar size"

  attr :shape, :atom,
    default: :circle,
    values: [:circle, :squircle, :hexagon, :triangle],
    doc: "avatar shape"

  attr :ring, :boolean, default: false, doc: "show ring border"

  attr :ring_color, :atom,
    default: :primary,
    values: [:primary, :secondary, :accent, :neutral],
    doc: "ring color"

  attr :online, :boolean, default: false, doc: "show online indicator"
  attr :offline, :boolean, default: false, doc: "show offline indicator"
  attr :class, :string, default: nil, doc: "additional classes"

  def avatar(assigns) do
    ~H"""
    <div class={[
      "avatar",
      @online && "online",
      @offline && "offline",
      placeholder?(@src) && "placeholder",
      @class
    ]}>
      <div class={[
        avatar_size_class(@size),
        avatar_shape_class(@shape),
        @ring && "ring ring-offset-base-100 ring-offset-2",
        @ring && ring_color_class(@ring_color),
        placeholder?(@src) && "bg-neutral text-neutral-content"
      ]}>
        <%= if @src do %>
          <img src={@src} alt="" />
        <% else %>
          <span class={placeholder_text_size(@size)}>{@placeholder || "?"}</span>
        <% end %>
      </div>
    </div>
    """
  end

  defp placeholder?(src), do: is_nil(src)

  defp avatar_size_class(:xs), do: "w-8"
  defp avatar_size_class(:sm), do: "w-12"
  defp avatar_size_class(:md), do: "w-16"
  defp avatar_size_class(:lg), do: "w-20"
  defp avatar_size_class(:xl), do: "w-24"

  defp avatar_shape_class(:circle), do: "rounded-full"
  defp avatar_shape_class(:squircle), do: "mask mask-squircle"
  defp avatar_shape_class(:hexagon), do: "mask mask-hexagon"
  defp avatar_shape_class(:triangle), do: "mask mask-triangle"

  defp ring_color_class(:primary), do: "ring-primary"
  defp ring_color_class(:secondary), do: "ring-secondary"
  defp ring_color_class(:accent), do: "ring-accent"
  defp ring_color_class(:neutral), do: "ring-neutral"

  defp placeholder_text_size(:xs), do: "text-xs"
  defp placeholder_text_size(:sm), do: "text-sm"
  defp placeholder_text_size(:md), do: "text-lg"
  defp placeholder_text_size(:lg), do: "text-xl"
  defp placeholder_text_size(:xl), do: "text-2xl"

  @doc """
  Renders an avatar group.

  ## Examples

      <.avatar_group>
        <.avatar src="/user1.jpg" />
        <.avatar src="/user2.jpg" />
        <.avatar placeholder="+5" />
      </.avatar_group>

  """
  attr :class, :string, default: nil, doc: "additional classes"
  slot :inner_block, required: true

  def avatar_group(assigns) do
    ~H"""
    <div class={["avatar-group -space-x-6 rtl:space-x-reverse", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # =============================================================================
  # BADGE
  # =============================================================================

  @doc """
  Renders a badge.

  ## Examples

      <.badge>Default</.badge>
      <.badge color={:primary}>Primary</.badge>
      <.badge color={:success} size={:lg}>Success</.badge>
      <.badge outline color={:info}>Info</.badge>

  """
  attr :color, :atom,
    default: nil,
    values: [
      nil,
      :primary,
      :secondary,
      :accent,
      :neutral,
      :ghost,
      :info,
      :success,
      :warning,
      :error
    ],
    doc: "badge color"

  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "badge size"
  attr :outline, :boolean, default: false, doc: "outline style"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "badge",
      badge_color_class(@color),
      badge_size_class(@size),
      @outline && "badge-outline",
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_color_class(nil), do: nil
  defp badge_color_class(:primary), do: "badge-primary"
  defp badge_color_class(:secondary), do: "badge-secondary"
  defp badge_color_class(:accent), do: "badge-accent"
  defp badge_color_class(:neutral), do: "badge-neutral"
  defp badge_color_class(:ghost), do: "badge-ghost"
  defp badge_color_class(:info), do: "badge-info"
  defp badge_color_class(:success), do: "badge-success"
  defp badge_color_class(:warning), do: "badge-warning"
  defp badge_color_class(:error), do: "badge-error"

  defp badge_size_class(:xs), do: "badge-xs"
  defp badge_size_class(:sm), do: "badge-sm"
  defp badge_size_class(:md), do: nil
  defp badge_size_class(:lg), do: "badge-lg"

  # =============================================================================
  # STAT
  # =============================================================================

  @doc """
  Renders a statistics display.

  ## Examples

      <.stats>
        <.stat title="Downloads" value="31K" description="Jan 1st - Feb 1st" />
        <.stat title="Users" value="4,200" description="+14% this month" />
      </.stats>

      <.stats vertical>
        <.stat title="Revenue" value="$12,000" icon="hero-currency-dollar" />
      </.stats>

  """
  attr :vertical, :boolean, default: false, doc: "vertical layout"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, required: true

  def stats(assigns) do
    ~H"""
    <div class={[
      "stats shadow",
      @vertical && "stats-vertical",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a single stat item within stats.

  ## Examples

      <.stat title="Users" value="4,200" />
      <.stat title="Revenue" value="$12K" description="+21%">
        <:figure>
          <.icon name="hero-currency-dollar" class="size-8 text-primary" />
        </:figure>
      </.stat>

  """
  attr :title, :string, required: true, doc: "stat title"
  attr :value, :string, required: true, doc: "stat value"
  attr :description, :string, default: nil, doc: "stat description"
  attr :icon, :string, default: nil, doc: "icon name"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :figure, doc: "custom figure content"
  slot :actions, doc: "action buttons"

  def stat(assigns) do
    ~H"""
    <div class={["stat", @class]}>
      <div :if={@figure != [] || @icon} class="stat-figure text-primary">
        <%= if @figure != [] do %>
          {render_slot(@figure)}
        <% else %>
          <.icon :if={@icon} name={@icon} class="size-8" />
        <% end %>
      </div>
      <div class="stat-title">{@title}</div>
      <div class="stat-value">{@value}</div>
      <div :if={@description} class="stat-desc">{@description}</div>
      <div :if={@actions != []} class="stat-actions">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  # =============================================================================
  # KBD (Keyboard)
  # =============================================================================

  @doc """
  Renders a keyboard key indicator.

  ## Examples

      <.kbd>K</.kbd>
      <.kbd size={:lg}>Enter</.kbd>
      Press <.kbd>Ctrl</.kbd> + <.kbd>C</.kbd> to copy

  """
  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "key size"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <kbd class={[
      "kbd",
      kbd_size_class(@size),
      @class
    ]}>
      {render_slot(@inner_block)}
    </kbd>
    """
  end

  defp kbd_size_class(:xs), do: "kbd-xs"
  defp kbd_size_class(:sm), do: "kbd-sm"
  defp kbd_size_class(:md), do: nil
  defp kbd_size_class(:lg), do: "kbd-lg"

  # =============================================================================
  # COUNTDOWN
  # =============================================================================

  @doc """
  Renders an animated countdown.

  Use CSS custom properties to set values dynamically.

  ## Examples

      <.countdown value={15} label="seconds" />

      <.countdown_group>
        <.countdown value={10} label="days" />
        <.countdown value={24} label="hours" />
        <.countdown value={37} label="min" />
        <.countdown value={48} label="sec" />
      </.countdown_group>

  """
  attr :value, :integer, required: true, doc: "countdown value (0-99)"
  attr :label, :string, default: nil, doc: "label below countdown"
  attr :class, :string, default: nil, doc: "additional classes"

  def countdown(assigns) do
    ~H"""
    <div class={["flex flex-col items-center", @class]}>
      <span class="countdown font-mono text-2xl">
        <span style={"--value:#{min(@value, 99)};"}></span>
      </span>
      <span :if={@label} class="text-xs">{@label}</span>
    </div>
    """
  end

  @doc """
  Wraps multiple countdown items.
  """
  attr :class, :string, default: nil, doc: "additional classes"
  slot :inner_block, required: true

  def countdown_group(assigns) do
    ~H"""
    <div class={["flex gap-4", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # =============================================================================
  # COLLAPSE / ACCORDION
  # =============================================================================

  @doc """
  Renders a collapsible content section.

  ## Examples

      <.collapse title="Click to open">
        Hidden content here.
      </.collapse>

      <.collapse title="With arrow" arrow>
        More content.
      </.collapse>

      <.collapse title="With plus" plus open>
        Initially open content.
      </.collapse>

  """
  attr :title, :string, required: true, doc: "collapse title"
  attr :open, :boolean, default: false, doc: "initially open"
  attr :arrow, :boolean, default: false, doc: "show arrow indicator"
  attr :plus, :boolean, default: false, doc: "show plus/minus indicator"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, required: true

  def collapse(assigns) do
    ~H"""
    <div class={[
      "collapse bg-base-200",
      @arrow && "collapse-arrow",
      @plus && "collapse-plus",
      @class
    ]}>
      <input type="checkbox" checked={@open} />
      <div class="collapse-title text-lg font-medium">
        {@title}
      </div>
      <div class="collapse-content">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders an accordion (group of mutually exclusive collapses).

  ## Examples

      <.accordion name="my-accordion">
        <:item title="Section 1">Content 1</:item>
        <:item title="Section 2" checked>Content 2</:item>
        <:item title="Section 3">Content 3</:item>
      </.accordion>

  """
  attr :name, :string, required: true, doc: "radio group name for mutual exclusion"
  attr :arrow, :boolean, default: true, doc: "show arrow indicator"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :item, required: true, doc: "accordion items" do
    attr :title, :string, required: true
    attr :checked, :boolean
  end

  def accordion(assigns) do
    ~H"""
    <div class={["join join-vertical w-full", @class]}>
      <div
        :for={item <- @item}
        class={[
          "collapse join-item border-base-300 border",
          @arrow && "collapse-arrow"
        ]}
      >
        <input type="radio" name={@name} checked={item[:checked]} />
        <div class="collapse-title text-lg font-medium">
          {item.title}
        </div>
        <div class="collapse-content">
          {render_slot([item])}
        </div>
      </div>
    </div>
    """
  end

  # =============================================================================
  # CHAT
  # =============================================================================

  @doc """
  Renders a chat bubble.

  ## Examples

      <.chat_bubble side={:start} message="Hello!">
        <:header>User 1 <time>12:45</time></:header>
        <:footer>Delivered</:footer>
      </.chat_bubble>

      <.chat_bubble side={:end} message="Hi there!" color={:primary}>
        <:avatar src="/avatar.jpg" />
      </.chat_bubble>

  """
  attr :side, :atom, default: :start, values: [:start, :end], doc: "bubble position"
  attr :message, :string, required: true, doc: "message content"

  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent, :info, :success, :warning, :error],
    doc: "bubble color"

  attr :class, :string, default: nil, doc: "additional classes"

  slot :avatar, doc: "avatar image" do
    attr :src, :string
  end

  slot :header, doc: "header content (name, time)"
  slot :footer, doc: "footer content (status)"

  def chat_bubble(assigns) do
    ~H"""
    <div class={[
      "chat",
      @side == :start && "chat-start",
      @side == :end && "chat-end",
      @class
    ]}>
      <div :if={@avatar != []} class="chat-image avatar">
        <div class="w-10 rounded-full">
          <img :for={av <- @avatar} src={av.src} alt="" />
        </div>
      </div>
      <div :if={@header != []} class="chat-header">
        {render_slot(@header)}
      </div>
      <div class={["chat-bubble", chat_bubble_color_class(@color)]}>
        {@message}
      </div>
      <div :if={@footer != []} class="chat-footer opacity-50">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end

  defp chat_bubble_color_class(nil), do: nil
  defp chat_bubble_color_class(:primary), do: "chat-bubble-primary"
  defp chat_bubble_color_class(:secondary), do: "chat-bubble-secondary"
  defp chat_bubble_color_class(:accent), do: "chat-bubble-accent"
  defp chat_bubble_color_class(:info), do: "chat-bubble-info"
  defp chat_bubble_color_class(:success), do: "chat-bubble-success"
  defp chat_bubble_color_class(:warning), do: "chat-bubble-warning"
  defp chat_bubble_color_class(:error), do: "chat-bubble-error"

  # =============================================================================
  # TIMELINE
  # =============================================================================

  @doc """
  Renders a timeline.

  ## Examples

      <.timeline>
        <:item title="Step 1" status={:complete}>First step done</:item>
        <:item title="Step 2" status={:current}>In progress</:item>
        <:item title="Step 3">Not started</:item>
      </.timeline>

      <.timeline horizontal>
        <:item time="2023">Event 1</:item>
        <:item time="2024">Event 2</:item>
      </.timeline>

  """
  attr :horizontal, :boolean, default: false, doc: "horizontal layout"
  attr :snap, :boolean, default: false, doc: "snap items to center"
  attr :compact, :boolean, default: false, doc: "compact mode"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :item, required: true, doc: "timeline items" do
    attr :title, :string
    attr :time, :string
    attr :status, :atom, values: [:pending, :current, :complete]
    attr :side, :atom, values: [:start, :end]
  end

  def timeline(assigns) do
    ~H"""
    <ul class={[
      "timeline",
      @horizontal && "timeline-horizontal",
      @snap && "timeline-snap-icon",
      @compact && "timeline-compact",
      @class
    ]}>
      <li :for={{item, idx} <- Enum.with_index(@item)}>
        <hr :if={idx > 0} class={item[:status] in [:complete, :current] && "bg-primary"} />
        <div
          :if={item[:time]}
          class={[
            "timeline-start",
            item[:side] == :end && "timeline-end"
          ]}
        >
          {item.time}
        </div>
        <div class="timeline-middle">
          <.icon
            name={timeline_icon(item[:status])}
            class={["size-5", item[:status] in [:complete, :current] && "text-primary"]}
          />
        </div>
        <div class={[
          "timeline-end timeline-box",
          item[:side] == :start && "timeline-start"
        ]}>
          <div :if={item[:title]} class="font-bold">{item.title}</div>
          {render_slot([item])}
        </div>
        <hr :if={idx < length(@item) - 1} class={item[:status] == :complete && "bg-primary"} />
      </li>
    </ul>
    """
  end

  defp timeline_icon(:complete), do: "hero-check-circle-solid"
  defp timeline_icon(:current), do: "hero-arrow-right-circle-solid"
  defp timeline_icon(_), do: "hero-ellipsis-horizontal-circle"

  # =============================================================================
  # DIFF
  # =============================================================================

  @doc """
  Renders a diff/comparison view.

  ## Examples

      <.diff>
        <:before>
          <img src="/before.jpg" alt="Before" />
        </:before>
        <:after_content>
          <img src="/after.jpg" alt="After" />
        </:after_content>
      </.diff>

  """
  attr :class, :string, default: nil, doc: "additional classes"

  slot :before, required: true, doc: "before content"
  slot :after_content, required: true, doc: "after content"

  def diff(assigns) do
    ~H"""
    <div class={["diff aspect-video", @class]}>
      <div class="diff-item-1">
        {render_slot(@before)}
      </div>
      <div class="diff-item-2">
        {render_slot(@after_content)}
      </div>
      <div class="diff-resizer"></div>
    </div>
    """
  end
end
