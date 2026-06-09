defmodule PerfectPaperWeb.DaisyNavigationComponents do
  @moduledoc """
  DaisyUI Navigation Components.

  Provides navigation-related components following DaisyUI's component structure:
  - Menu (vertical/horizontal navigation lists)
  - Navbar (top navigation bar)
  - Breadcrumbs (path navigation)
  - Tabs (tabbed navigation)
  - Steps (progress steps)
  - Pagination (page navigation)
  - Bottom Navigation (mobile bottom nav)
  - Link (styled links)

  See https://daisyui.com/components/ for reference.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  # =============================================================================
  # MENU
  # =============================================================================

  @doc """
  Renders a menu navigation list.

  ## Examples

      <.menu>
        <:item>
          <.link navigate="/">Home</.link>
        </:item>
        <:item>
          <.link navigate="/about">About</.link>
        </:item>
      </.menu>

      <.menu horizontal class="bg-base-200 rounded-box">
        <:item><a>Item 1</a></:item>
        <:item><a>Item 2</a></:item>
      </.menu>

  """
  attr :horizontal, :boolean, default: false, doc: "horizontal layout"
  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "menu size"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :title, doc: "menu title/section header"

  slot :item, required: true, doc: "menu items" do
    attr :disabled, :boolean, doc: "disabled state"
    attr :active, :boolean, doc: "active state"
  end

  def menu(assigns) do
    ~H"""
    <ul class={[
      "menu",
      @horizontal && "menu-horizontal",
      menu_size_class(@size),
      @class
    ]}>
      <li :if={@title != []} class="menu-title">
        {render_slot(@title)}
      </li>
      <li
        :for={item <- @item}
        class={[
          item[:disabled] && "disabled",
          item[:active] && "active"
        ]}
      >
        {render_slot([item])}
      </li>
    </ul>
    """
  end

  defp menu_size_class(:xs), do: "menu-xs"
  defp menu_size_class(:sm), do: "menu-sm"
  defp menu_size_class(:md), do: nil
  defp menu_size_class(:lg), do: "menu-lg"

  @doc """
  Renders a collapsible submenu within a menu.

  ## Examples

      <.menu>
        <:item><a>Item 1</a></:item>
        <:item>
          <.submenu label="Parent">
            <:item><a>Child 1</a></:item>
            <:item><a>Child 2</a></:item>
          </.submenu>
        </:item>
      </.menu>

  """
  attr :label, :string, required: true, doc: "submenu label"
  attr :open, :boolean, default: false, doc: "initially open"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :item, required: true, doc: "submenu items"

  def submenu(assigns) do
    ~H"""
    <details open={@open} class={@class}>
      <summary>{@label}</summary>
      <ul>
        <li :for={item <- @item}>
          {render_slot([item])}
        </li>
      </ul>
    </details>
    """
  end

  # =============================================================================
  # NAVBAR
  # =============================================================================

  @doc """
  Renders a navbar component.

  ## Examples

      <.navbar>
        <:start>
          <a class="btn btn-ghost text-xl">Logo</a>
        </:start>
        <:center>
          <a class="btn btn-ghost">Home</a>
          <a class="btn btn-ghost">About</a>
        </:center>
        <:navbar_end>
          <button class="btn btn-primary">Login</button>
        </:navbar_end>
      </.navbar>

  """
  attr :class, :string, default: nil, doc: "additional classes"

  slot :start, doc: "left section content"
  slot :center, doc: "center section content"
  slot :navbar_end, doc: "right section content"

  def navbar(assigns) do
    ~H"""
    <div class={["navbar bg-base-100", @class]}>
      <div :if={@start != []} class="navbar-start">
        {render_slot(@start)}
      </div>
      <div :if={@center != []} class="navbar-center">
        {render_slot(@center)}
      </div>
      <div :if={@navbar_end != []} class="navbar-end">
        {render_slot(@navbar_end)}
      </div>
    </div>
    """
  end

  # =============================================================================
  # BREADCRUMBS
  # =============================================================================

  @doc """
  Renders breadcrumb navigation.

  Supports both `navigate` (full page nav) and `patch` (LiveView patch) on crumbs.
  The last crumb (no navigate/patch) renders as the current page.

  Callers should include a home crumb using `~p` for compile-time route verification:

      <.breadcrumbs>
        <:crumb navigate={~p"/documents"} icon="hero-home-mini"></:crumb>
        <:crumb navigate={~p"/documents"}>Documents</:crumb>
        <:crumb>Current Page</:crumb>
      </.breadcrumbs>

  """
  attr :class, :string, default: nil, doc: "additional classes"

  slot :crumb, required: true, doc: "breadcrumb items" do
    attr :navigate, :string, doc: "full navigation path"
    attr :patch, :string, doc: "LiveView patch path"
    attr :icon, :string, doc: "heroicon name"
  end

  def breadcrumbs(assigns) do
    ~H"""
    <div class={["breadcrumbs text-sm", @class]} aria-label="Breadcrumb">
      <ul>
        <li :for={crumb <- @crumb}>
          <%= if crumb[:navigate] || crumb[:patch] do %>
            <.link
              navigate={crumb[:navigate]}
              patch={crumb[:patch]}
              class="flex items-center gap-1 hover:text-primary"
            >
              <.icon :if={crumb[:icon]} name={crumb.icon} class="size-4" />
              {render_slot([crumb])}
            </.link>
          <% else %>
            <span class="flex items-center gap-1 font-medium">
              <.icon :if={crumb[:icon]} name={crumb.icon} class="size-4" />
              {render_slot([crumb])}
            </span>
          <% end %>
        </li>
      </ul>
    </div>
    """
  end

  # =============================================================================
  # TABS
  # =============================================================================

  @doc """
  Renders tab navigation.

  ## Examples

      <.tabs>
        <:tab active>Tab 1</:tab>
        <:tab>Tab 2</:tab>
        <:tab>Tab 3</:tab>
      </.tabs>

      <.tabs variant={:boxed}>
        <:tab navigate="/tab1" active>Tab 1</:tab>
        <:tab navigate="/tab2">Tab 2</:tab>
      </.tabs>

      <.tabs variant={:lifted} size={:lg}>
        <:tab phx-click="select_tab" phx-value-tab="1" active>Tab 1</:tab>
        <:tab phx-click="select_tab" phx-value-tab="2">Tab 2</:tab>
      </.tabs>

  """
  attr :variant, :atom,
    default: :default,
    values: [:default, :boxed, :lifted, :bordered],
    doc: "tab style"

  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "tab size"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :tab, required: true, doc: "tab items" do
    attr :active, :boolean, doc: "active state"
    attr :disabled, :boolean, doc: "disabled state"
    attr :navigate, :string, doc: "navigation path"
    attr :href, :string, doc: "link href"
    attr :method, :string, doc: "HTTP method for link"
  end

  def tabs(assigns) do
    ~H"""
    <div
      role="tablist"
      class={[
        "tabs",
        tab_variant_class(@variant),
        tab_size_class(@size),
        @class
      ]}
    >
      <%= for tab <- @tab do %>
        <%= if tab[:navigate] do %>
          <.link
            navigate={tab[:navigate]}
            role="tab"
            class={[
              "tab",
              tab[:active] && "tab-active",
              tab[:disabled] && "tab-disabled"
            ]}
          >
            {render_slot([tab])}
          </.link>
        <% else %>
          <button
            type="button"
            role="tab"
            class={[
              "tab",
              tab[:active] && "tab-active",
              tab[:disabled] && "tab-disabled"
            ]}
            disabled={tab[:disabled]}
            {assigns_to_attributes(tab, [:active, :disabled, :navigate])}
          >
            {render_slot([tab])}
          </button>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp tab_variant_class(:default), do: nil
  defp tab_variant_class(:boxed), do: "tabs-boxed"
  defp tab_variant_class(:lifted), do: "tabs-lifted"
  defp tab_variant_class(:bordered), do: "tabs-bordered"

  defp tab_size_class(:xs), do: "tabs-xs"
  defp tab_size_class(:sm), do: "tabs-sm"
  defp tab_size_class(:md), do: nil
  defp tab_size_class(:lg), do: "tabs-lg"

  # =============================================================================
  # STEPS
  # =============================================================================

  @doc """
  Renders step/progress indicators.

  ## Examples

      <.steps>
        <:step status={:complete}>Register</:step>
        <:step status={:current}>Choose Plan</:step>
        <:step>Payment</:step>
        <:step>Confirm</:step>
      </.steps>

      <.steps vertical>
        <:step status={:complete} icon="hero-check">Step 1</:step>
        <:step status={:current}>Step 2</:step>
        <:step status={:error}>Step 3</:step>
      </.steps>

  """
  attr :vertical, :boolean, default: false, doc: "vertical layout"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :step, required: true, doc: "step items" do
    attr :status, :atom, values: [:pending, :current, :complete, :error], doc: "step status"
    attr :icon, :string, doc: "custom icon name"
    attr :data_content, :string, doc: "custom step number/symbol"
  end

  def steps(assigns) do
    ~H"""
    <ul class={[
      "steps",
      @vertical && "steps-vertical",
      @class
    ]}>
      <li
        :for={step <- @step}
        class={[
          "step",
          step_status_class(step[:status])
        ]}
        data-content={step[:data_content]}
      >
        <%= if step[:icon] do %>
          <span class="flex items-center gap-2">
            <.icon name={step.icon} class="size-4" />
            {render_slot([step])}
          </span>
        <% else %>
          {render_slot([step])}
        <% end %>
      </li>
    </ul>
    """
  end

  defp step_status_class(nil), do: nil
  defp step_status_class(:pending), do: nil
  defp step_status_class(:current), do: "step-primary"
  defp step_status_class(:complete), do: "step-primary"
  defp step_status_class(:error), do: "step-error"

  # =============================================================================
  # BOTTOM NAVIGATION
  # =============================================================================

  @doc """
  Renders a bottom navigation bar for mobile.

  ## Examples

      <.bottom_nav>
        <:item icon="hero-home" label="Home" navigate="/" active />
        <:item icon="hero-magnifying-glass" label="Search" navigate="/search" />
        <:item icon="hero-user" label="Profile" navigate="/profile" />
      </.bottom_nav>

  """
  attr :class, :string, default: nil, doc: "additional classes"

  slot :item, required: true, doc: "navigation items" do
    attr :icon, :string, required: true, doc: "heroicon name"
    attr :label, :string, doc: "item label"
    attr :navigate, :string, doc: "navigation path"
    attr :active, :boolean, doc: "active state"
    attr :disabled, :boolean, doc: "disabled state"
    attr :badge, :string, doc: "badge content"
  end

  def bottom_nav(assigns) do
    ~H"""
    <div class={["dock dock-sm", @class]}>
      <%= for item <- @item do %>
        <%= if item[:navigate] do %>
          <.link
            navigate={item[:navigate]}
            class={[item[:active] && "dock-active", item[:disabled] && "disabled"]}
            aria-current={item[:active] && "page"}
          >
            <div class="relative">
              <.icon name={item.icon} class="size-5" />
              <span
                :if={item[:badge]}
                class="badge badge-xs badge-primary absolute -top-2 -right-2"
              >
                {item.badge}
              </span>
            </div>
            <span :if={item[:label]} class="dock-label">{item.label}</span>
          </.link>
        <% else %>
          <button
            type="button"
            class={[item[:active] && "dock-active", item[:disabled] && "disabled"]}
            disabled={item[:disabled]}
          >
            <div class="relative">
              <.icon name={item.icon} class="size-5" />
              <span
                :if={item[:badge]}
                class="badge badge-xs badge-primary absolute -top-2 -right-2"
              >
                {item.badge}
              </span>
            </div>
            <span :if={item[:label]} class="dock-label">{item.label}</span>
          </button>
        <% end %>
      <% end %>
    </div>
    """
  end

  # =============================================================================
  # LINK (Styled)
  # =============================================================================

  @doc """
  Renders a styled link.

  ## Examples

      <.styled_link navigate="/about">About Us</.styled_link>
      <.styled_link href="https://perfectpaper.ink" color={:primary}>External</.styled_link>
      <.styled_link navigate="/help" color={:secondary} hover>Help</.styled_link>

  """
  attr :color, :atom,
    default: :default,
    values: [:default, :primary, :secondary, :accent, :neutral, :info, :success, :warning, :error],
    doc: "link color"

  attr :hover, :boolean, default: false, doc: "only show underline on hover"
  attr :class, :string, default: nil, doc: "additional classes"
  attr :rest, :global, include: ~w(navigate href patch method download)

  slot :inner_block, required: true

  def styled_link(assigns) do
    ~H"""
    <.link
      class={[
        "link",
        link_color_class(@color),
        @hover && "link-hover",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp link_color_class(:default), do: nil
  defp link_color_class(:primary), do: "link-primary"
  defp link_color_class(:secondary), do: "link-secondary"
  defp link_color_class(:accent), do: "link-accent"
  defp link_color_class(:neutral), do: "link-neutral"
  defp link_color_class(:info), do: "link-info"
  defp link_color_class(:success), do: "link-success"
  defp link_color_class(:warning), do: "link-warning"
  defp link_color_class(:error), do: "link-error"
end
