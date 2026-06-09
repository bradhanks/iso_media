defmodule PerfectPaperWeb.DaisyLayoutComponents do
  @moduledoc """
  DaisyUI Layout Components.

  Provides layout-related components following DaisyUI's component structure:
  - Drawer (sidebar navigation)
  - Indicator (corner badges/notifications)
  - Stack (overlapping elements)
  - Divider (horizontal/vertical separators)
  - Footer (page footer)
  - Hero (hero sections)
  - Artboard (device frame mockups)

  See https://daisyui.com/components/ for reference.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  # =============================================================================
  # DRAWER
  # =============================================================================

  @doc """
  Renders a drawer layout with sidebar navigation.

  The drawer provides a responsive sidebar that:
  - Is always visible on large screens (lg+)
  - Slides in from the side on smaller screens via toggle

  ## Examples

      <.drawer id="main-drawer">
        <:sidebar>
          <.drawer_nav items={@nav_items} current_path={@current_path} />
        </:sidebar>
        <:content>
          <main>Your page content</main>
        </:content>
      </.drawer>

      <.drawer id="main-drawer" side={:end} class="lg:drawer-open">
        ...
      </.drawer>

  """
  attr :id, :string, required: true, doc: "unique drawer ID for toggle control"
  attr :side, :atom, default: :start, values: [:start, :end], doc: "sidebar position"
  attr :class, :string, default: nil, doc: "additional classes for drawer wrapper"
  attr :sidebar_class, :string, default: nil, doc: "additional classes for sidebar"
  attr :content_class, :string, default: nil, doc: "additional classes for content area"
  attr :overlay, :boolean, default: true, doc: "show overlay when drawer is open on mobile"
  attr :open, :boolean, default: false, doc: "force drawer open (useful for lg+ screens)"

  slot :sidebar, required: true, doc: "sidebar content"
  slot :content, required: true, doc: "main content area"

  def drawer(assigns) do
    ~H"""
    <div class={[
      "drawer",
      @side == :end && "drawer-end",
      @open && "drawer-open",
      "lg:drawer-open",
      @class
    ]}>
      <input id={@id} type="checkbox" class="drawer-toggle" aria-label={gettext("Toggle sidebar")} />

      <div class={["drawer-content", @content_class]}>
        {render_slot(@content)}
      </div>

      <div class={["drawer-side z-40", @sidebar_class]}>
        <label
          :if={@overlay}
          for={@id}
          class="drawer-overlay"
          aria-label={gettext("Close sidebar")}
        />
        <aside class="bg-base-200 min-h-full w-72 lg:w-80">
          {render_slot(@sidebar)}
        </aside>
      </div>
    </div>
    """
  end

  @doc """
  Renders the drawer toggle button for mobile.

  Place this in your navbar or header to allow users to open the drawer on mobile.

  ## Examples

      <.drawer_toggle target="main-drawer" />

      <.drawer_toggle target="main-drawer" class="lg:hidden">
        <.icon name="hero-bars-3" class="size-6" />
      </.drawer_toggle>

  """
  attr :target, :string, required: true, doc: "ID of the drawer to toggle"
  attr :class, :string, default: nil, doc: "additional classes"
  attr :rest, :global

  slot :inner_block, doc: "custom toggle content (defaults to hamburger icon)"

  def drawer_toggle(assigns) do
    ~H"""
    <label
      for={@target}
      class={["btn btn-ghost btn-square lg:hidden cursor-pointer", @class]}
      aria-label={gettext("Open sidebar")}
      {@rest}
    >
      <%= if @inner_block == [] do %>
        <.icon name="hero-bars-3" class="size-6" />
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </label>
    """
  end

  @doc """
  Renders a navigation menu for use inside a drawer sidebar.

  ## Examples

      <.drawer_nav
        items={[
          %{label: "Home", path: "/", icon: "hero-home"},
          %{label: "Documents", path: "/documents", icon: "hero-document-text"},
          %{label: "Tasks", path: "/tasks", icon: "hero-clipboard-document-check", badge: "8"}
        ]}
        current_path={@current_path}
      />

  """
  attr :items, :list,
    required: true,
    doc: "list of nav items with :label, :path, :icon, optional :badge"

  attr :current_path, :string, default: nil, doc: "current page path for active state"
  attr :class, :string, default: nil, doc: "additional classes for menu"

  def drawer_nav(assigns) do
    ~H"""
    <ul class={["menu p-4 gap-1", @class]} role="navigation">
      <li :for={item <- @items}>
        <.link
          navigate={item.path}
          class={[
            "flex items-center gap-3",
            active?(item.path, @current_path) && "active"
          ]}
          aria-current={active?(item.path, @current_path) && "page"}
        >
          <.icon :if={item[:icon]} name={item.icon} class="size-5" />
          <span class="flex-1">{item.label}</span>
          <span :if={item[:badge]} class="badge badge-sm badge-neutral">
            {item.badge}
          </span>
        </.link>
      </li>
    </ul>
    """
  end

  defp active?(item_path, current_path) when is_binary(current_path) do
    current_path == item_path || String.starts_with?(current_path, item_path <> "/")
  end

  defp active?(_, _), do: false

  @doc """
  Renders the drawer header section with logo and optional search.

  ## Examples

      <.drawer_header>
        <img src="/images/logo.svg" alt="Logo" class="h-8" />
      </.drawer_header>

      <.drawer_header search search_placeholder="Search..." on_search="open_search">
        <span class="text-xl font-bold">PerfectPaper</span>
      </.drawer_header>

  """
  attr :class, :string, default: nil, doc: "additional classes"
  attr :search, :boolean, default: false, doc: "show search input"
  attr :search_placeholder, :string, default: "Search...", doc: "search input placeholder"
  attr :search_shortcut, :string, default: "⌘K", doc: "keyboard shortcut hint"
  attr :on_search, :string, default: nil, doc: "event to trigger on search focus/click"

  slot :inner_block, required: true, doc: "logo/branding content"

  def drawer_header(assigns) do
    ~H"""
    <div class={["p-4 space-y-4", @class]}>
      <div class="flex items-center gap-2">
        {render_slot(@inner_block)}
      </div>

      <div :if={@search}>
        <div class="join w-full">
          <button
            type="button"
            class="btn btn-ghost join-item flex-1 justify-start gap-2 font-normal text-base-content/60"
            phx-click={@on_search}
            aria-label={gettext("Open search")}
          >
            <.icon name="hero-magnifying-glass" class="size-5" />
            <span class="flex-1 text-left">{@search_placeholder}</span>
            <kbd class="kbd kbd-sm">{@search_shortcut}</kbd>
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the drawer footer section with user profile.

  ## Examples

      <.drawer_footer
        user_name="Olivia Rhye"
        user_email="olivia@perfectpaper.ink"
        avatar_url="/images/avatar.jpg"
      />

      <.drawer_footer
        user_name={@current_user.name}
        user_email={@current_user.email}
        online
      >
        <:menu>
          <li><.link navigate="/settings">Settings</.link></li>
          <li><.link href="/logout" method="delete">Sign out</.link></li>
        </:menu>
      </.drawer_footer>

  """
  attr :user_name, :string, required: true, doc: "user display name"
  attr :user_email, :string, required: true, doc: "user email"
  attr :avatar_url, :string, default: nil, doc: "user avatar URL"
  attr :online, :boolean, default: false, doc: "show online status indicator"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :menu, doc: "dropdown menu items"

  def drawer_footer(assigns) do
    ~H"""
    <div class={["p-4 border-t border-base-300", @class]}>
      <div class="dropdown dropdown-top w-full">
        <div
          tabindex="0"
          role="button"
          class="btn btn-ghost w-full justify-start gap-3 h-auto py-2"
        >
          <div class="avatar placeholder" aria-hidden="true">
            <div class={[
              "w-10 rounded-full",
              @avatar_url && "ring ring-base-300 ring-offset-base-100 ring-offset-2",
              !@avatar_url && "bg-neutral text-neutral-content"
            ]}>
              <%= if @avatar_url do %>
                <img src={@avatar_url} alt="" />
              <% else %>
                <span class="text-sm">{initials(@user_name)}</span>
              <% end %>
            </div>
            <span
              :if={@online}
              class="absolute bottom-0 right-0 block size-3 rounded-full bg-success ring-2 ring-base-200"
              aria-label={gettext("Online")}
            />
          </div>
          <div class="flex-1 text-left min-w-0">
            <p class="font-semibold text-sm truncate">{@user_name}</p>
            <p class="text-xs text-base-content/60 truncate">{@user_email}</p>
          </div>
          <.icon name="hero-chevron-up-down" class="size-4 text-base-content/60" />
        </div>
        <ul
          :if={@menu != []}
          tabindex="0"
          class="dropdown-content menu bg-base-100 rounded-box z-50 w-full p-2 shadow-lg"
        >
          {render_slot(@menu)}
        </ul>
      </div>
    </div>
    """
  end

  defp initials(name) when is_binary(name) do
    name
    |> String.split()
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp initials(_), do: "?"

  @doc """
  Renders a feature/announcement card for the drawer sidebar.

  ## Examples

      <.drawer_card
        title="New features available!"
        description="Check out the new dashboard view."
        image_url="/images/feature.jpg"
      >
        <:actions>
          <button class="btn btn-ghost btn-sm">Dismiss</button>
          <button class="btn btn-link btn-sm">Learn more</button>
        </:actions>
      </.drawer_card>

  """
  attr :title, :string, required: true, doc: "card title"
  attr :description, :string, default: nil, doc: "card description"
  attr :image_url, :string, default: nil, doc: "optional image URL"
  attr :dismissible, :boolean, default: true, doc: "show dismiss button"
  attr :on_dismiss, :string, default: nil, doc: "dismiss event name"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :actions, doc: "action buttons"

  def drawer_card(assigns) do
    ~H"""
    <div class={["card bg-base-100 shadow-sm mx-4 mb-4", @class]}>
      <button
        :if={@dismissible}
        type="button"
        class="btn btn-ghost btn-xs btn-square absolute top-2 right-2"
        phx-click={@on_dismiss}
        aria-label={gettext("Dismiss")}
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
      <div class="card-body p-4">
        <h3 class="card-title text-sm">{@title}</h3>
        <p :if={@description} class="text-sm text-base-content/70">{@description}</p>
        <figure :if={@image_url} class="mt-2">
          <img src={@image_url} alt="" class="rounded-lg w-full aspect-video object-cover" />
        </figure>
        <div :if={@actions != []} class="card-actions mt-2">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  # =============================================================================
  # INDICATOR
  # =============================================================================

  @doc """
  Renders an indicator (badge positioned on corner of child element).

  ## Examples

      <.indicator>
        <:badge>99+</:badge>
        <button class="btn">Inbox</button>
      </.indicator>

      <.indicator position={:top_start}>
        <:badge class="badge-primary">New</:badge>
        <div class="card">...</div>
      </.indicator>

  """
  attr :position, :atom,
    default: :top_end,
    values: [
      :top_start,
      :top_center,
      :top_end,
      :middle_start,
      :middle_center,
      :middle_end,
      :bottom_start,
      :bottom_center,
      :bottom_end
    ],
    doc: "badge position"

  attr :class, :string, default: nil, doc: "additional classes for wrapper"

  slot :badge, required: true, doc: "the indicator badge content" do
    attr :class, :string, doc: "badge classes"
  end

  slot :inner_block, required: true, doc: "the element to attach indicator to"

  def indicator(assigns) do
    ~H"""
    <div class={["indicator", @class]}>
      <span
        :for={badge <- @badge}
        class={[
          "indicator-item badge",
          position_class(@position),
          badge[:class]
        ]}
      >
        {render_slot([badge])}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp position_class(:top_start), do: "indicator-top indicator-start"
  defp position_class(:top_center), do: "indicator-top indicator-center"
  defp position_class(:top_end), do: "indicator-top indicator-end"
  defp position_class(:middle_start), do: "indicator-middle indicator-start"
  defp position_class(:middle_center), do: "indicator-middle indicator-center"
  defp position_class(:middle_end), do: "indicator-middle indicator-end"
  defp position_class(:bottom_start), do: "indicator-bottom indicator-start"
  defp position_class(:bottom_center), do: "indicator-bottom indicator-center"
  defp position_class(:bottom_end), do: "indicator-bottom indicator-end"

  # =============================================================================
  # STACK
  # =============================================================================

  @doc """
  Renders stacked elements (cards/images on top of each other).

  ## Examples

      <.stack>
        <div class="card bg-primary text-primary-content">Card 1</div>
        <div class="card bg-secondary text-secondary-content">Card 2</div>
        <div class="card bg-accent text-accent-content">Card 3</div>
      </.stack>

      <.stack align={:top}>
        <img src="/img1.jpg" />
        <img src="/img2.jpg" />
      </.stack>

  """
  attr :align, :atom, default: :bottom, values: [:top, :bottom], doc: "stack alignment"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, required: true

  def stack(assigns) do
    ~H"""
    <div class={[
      "stack",
      @align == :top && "stack-top",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # =============================================================================
  # DIVIDER
  # =============================================================================

  @doc """
  Renders a divider line with optional text.

  ## Examples

      <.divider />
      <.divider>OR</.divider>
      <.divider direction={:horizontal} class="my-4">Section</.divider>
      <.divider direction={:vertical} class="mx-4" />

  """
  attr :direction, :atom,
    default: :horizontal,
    values: [:horizontal, :vertical],
    doc: "divider direction"

  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, doc: "optional text content"

  def divider(assigns) do
    ~H"""
    <div class={[
      "divider",
      @direction == :vertical && "divider-horizontal",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # =============================================================================
  # HERO
  # =============================================================================

  @doc """
  Renders a hero section with centered content.

  ## Examples

      <.hero>
        <h1 class="text-5xl font-bold">Hello there</h1>
        <p class="py-6">Welcome to our site.</p>
        <button class="btn btn-primary">Get Started</button>
      </.hero>

      <.hero overlay image_url="/images/hero-bg.jpg">
        <h1 class="text-5xl font-bold text-white">Hello</h1>
      </.hero>

  """
  attr :image_url, :string, default: nil, doc: "background image URL"
  attr :overlay, :boolean, default: false, doc: "add dark overlay on image"
  attr :class, :string, default: nil, doc: "additional classes"
  attr :content_class, :string, default: nil, doc: "classes for content wrapper"

  slot :inner_block, required: true

  def hero(assigns) do
    ~H"""
    <div
      class={["hero min-h-96", @class]}
      style={@image_url && "background-image: url(#{URI.encode(@image_url)});"}
    >
      <div :if={@overlay && @image_url} class="hero-overlay bg-opacity-60" />
      <div class={["hero-content text-center", @overlay && "text-neutral-content", @content_class]}>
        <div class="max-w-md">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  # =============================================================================
  # FOOTER (Page Footer)
  # =============================================================================

  @doc """
  Renders a page footer with multiple columns.

  ## Examples

      <.page_footer>
        <:column title="Services">
          <a class="link link-hover">Branding</a>
          <a class="link link-hover">Design</a>
        </:column>
        <:column title="Company">
          <a class="link link-hover">About</a>
          <a class="link link-hover">Contact</a>
        </:column>
      </.page_footer>

  """
  attr :class, :string, default: nil, doc: "additional classes"
  attr :center, :boolean, default: false, doc: "center the footer content"

  slot :column, doc: "footer columns" do
    attr :title, :string, required: true
  end

  slot :inner_block, doc: "additional footer content (e.g., copyright)"

  def page_footer(assigns) do
    ~H"""
    <footer class={[
      "footer p-10 bg-base-200 text-base-content",
      @center && "footer-center",
      @class
    ]}>
      <nav :for={col <- @column}>
        <h6 class="footer-title">{col.title}</h6>
        {render_slot([col])}
      </nav>
      {render_slot(@inner_block)}
    </footer>
    """
  end

  # =============================================================================
  # ARTBOARD
  # =============================================================================

  @doc """
  Renders an artboard container for design mockups.

  ## Examples

      <.artboard size={:phone_1}>
        <p>320×568</p>
      </.artboard>

      <.artboard size={:phone_4} horizontal>
        <p>Landscape phone</p>
      </.artboard>

  """
  attr :size, :atom,
    default: :phone_1,
    values: [:phone_1, :phone_2, :phone_3, :phone_4, :phone_5, :phone_6],
    doc: "artboard size preset"

  attr :horizontal, :boolean, default: false, doc: "landscape orientation"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, required: true

  def artboard(assigns) do
    ~H"""
    <div class={[
      "artboard artboard-demo",
      size_class(@size),
      @horizontal && "artboard-horizontal",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp size_class(:phone_1), do: "phone-1"
  defp size_class(:phone_2), do: "phone-2"
  defp size_class(:phone_3), do: "phone-3"
  defp size_class(:phone_4), do: "phone-4"
  defp size_class(:phone_5), do: "phone-5"
  defp size_class(:phone_6), do: "phone-6"
end
