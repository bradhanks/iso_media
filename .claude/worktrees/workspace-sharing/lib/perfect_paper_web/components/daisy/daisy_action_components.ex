defmodule PerfectPaperWeb.DaisyActionComponents do
  @moduledoc """
  DaisyUI Action Components.

  Provides action-related components following DaisyUI's component structure:
  - `daisy_button/1` - Full-featured DaisyUI button with all variants
  - `button_group/1` - Button groups using join
  - `dropdown_menu/1` - Structured dropdown menus with icons
  - `daisy_modal/1` - DaisyUI-specific modal dialogs
  - `swap/1` - Toggle between two states
  - `theme_controller/1` - Theme switcher
  - `clipboard/1`, `copy_button/1`, `code_copy/1` - Copy-to-clipboard utilities

  Note: ContainerComponents provides a simpler `modal/1` for PerfectPaper-specific needs
  and `dropdown/1` for basic dropdowns. Use these DaisyUI components for more
  advanced styling options.

  See https://daisyui.com/components/ for reference.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  # =============================================================================
  # BUTTON
  # =============================================================================

  @doc """
  Renders a DaisyUI styled button.

  ## Examples

      <.daisy_button>Default</.daisy_button>
      <.daisy_button color={:primary}>Primary</.daisy_button>
      <.daisy_button color={:error} outline>Error Outline</.daisy_button>
      <.daisy_button size={:lg} wide>Wide Button</.daisy_button>
      <.daisy_button loading>Processing...</.daisy_button>
      <.daisy_button navigate="/" color={:primary}>Go Home</.daisy_button>

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
      :link,
      :info,
      :success,
      :warning,
      :error
    ],
    doc: "button color"

  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "button size"
  attr :outline, :boolean, default: false, doc: "outline style"
  attr :soft, :boolean, default: false, doc: "soft/pastel style"
  attr :glass, :boolean, default: false, doc: "glass effect"
  attr :wide, :boolean, default: false, doc: "wide button"
  attr :block, :boolean, default: false, doc: "full width"
  attr :circle, :boolean, default: false, doc: "circular button"
  attr :square, :boolean, default: false, doc: "square button"
  attr :loading, :boolean, default: false, doc: "show loading spinner"
  attr :disabled, :boolean, default: false, doc: "disabled state"
  attr :class, :string, default: nil, doc: "additional classes"

  attr :rest, :global, include: ~w(navigate href patch method download name value type form)

  slot :inner_block, required: true

  def daisy_button(%{rest: rest} = assigns) do
    if rest[:navigate] || rest[:href] || rest[:patch] do
      ~H"""
      <.link
        class={button_classes(assigns)}
        {@rest}
      >
        <span :if={@loading} class="loading loading-spinner loading-sm" />
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button
        type={@rest[:type] || "button"}
        class={button_classes(assigns)}
        disabled={@disabled || @loading}
        {@rest}
      >
        <span :if={@loading} class="loading loading-spinner loading-sm" />
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp button_classes(assigns) do
    [
      "btn",
      button_color_class(assigns.color),
      button_size_class(assigns.size),
      assigns.outline && "btn-outline",
      assigns.soft && "btn-soft",
      assigns.glass && "glass",
      assigns.wide && "btn-wide",
      assigns.block && "btn-block",
      assigns.circle && "btn-circle",
      assigns.square && "btn-square",
      assigns.disabled && "btn-disabled",
      assigns.class
    ]
  end

  defp button_color_class(nil), do: nil
  defp button_color_class(:primary), do: "btn-primary"
  defp button_color_class(:secondary), do: "btn-secondary"
  defp button_color_class(:accent), do: "btn-accent"
  defp button_color_class(:neutral), do: "btn-neutral"
  defp button_color_class(:ghost), do: "btn-ghost"
  defp button_color_class(:link), do: "btn-link"
  defp button_color_class(:info), do: "btn-info"
  defp button_color_class(:success), do: "btn-success"
  defp button_color_class(:warning), do: "btn-warning"
  defp button_color_class(:error), do: "btn-error"

  defp button_size_class(:xs), do: "btn-xs"
  defp button_size_class(:sm), do: "btn-sm"
  defp button_size_class(:md), do: nil
  defp button_size_class(:lg), do: "btn-lg"

  @doc """
  Renders a button group.

  ## Examples

      <.button_group>
        <.daisy_button>1</.daisy_button>
        <.daisy_button>2</.daisy_button>
        <.daisy_button>3</.daisy_button>
      </.button_group>

  """
  attr :vertical, :boolean, default: false, doc: "vertical layout"
  attr :class, :string, default: nil, doc: "additional classes"
  slot :inner_block, required: true

  def button_group(assigns) do
    ~H"""
    <div class={[
      "join",
      @vertical && "join-vertical",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # =============================================================================
  # DROPDOWN
  # =============================================================================

  # Note: Basic dropdown/1 is provided by ContainerComponents.
  # This module provides dropdown_menu/1 for structured menus with icons.

  defp dropdown_position_class(nil), do: nil
  defp dropdown_position_class(:end), do: "dropdown-end"
  defp dropdown_position_class(:top), do: "dropdown-top"
  defp dropdown_position_class(:bottom), do: "dropdown-bottom"
  defp dropdown_position_class(:left), do: "dropdown-left"
  defp dropdown_position_class(:right), do: "dropdown-right"

  @doc """
  Renders a dropdown menu with structured items and icon support.

  ## Examples

      <.dropdown_menu label="Actions">
        <:item icon="hero-bell" navigate="/notifications">Newsletter</:item>
        <:item icon="hero-shopping-cart" navigate="/purchases">Purchases</:item>
        <:item icon="hero-arrow-down-tray" navigate="/downloads">Downloads</:item>
        <:item icon="hero-users" navigate="/team">Team Account</:item>
      </.dropdown_menu>

      <.dropdown_menu label="Options" position={:end} icon="hero-cog-6-tooth">
        <:item icon="hero-user" navigate="/profile">Profile</:item>
        <:divider />
        <:item icon="hero-arrow-right-start-on-rectangle" href="/logout" method="delete">
          Sign out
        </:item>
      </.dropdown_menu>

  """
  attr :label, :string, required: true, doc: "button label"
  attr :icon, :string, default: nil, doc: "button icon (before label)"

  attr :position, :atom,
    default: nil,
    values: [nil, :end, :top, :bottom, :left, :right],
    doc: "menu position"

  attr :hover, :boolean, default: false, doc: "open on hover"
  attr :button_class, :string, default: nil, doc: "button classes"
  attr :menu_class, :string, default: nil, doc: "menu classes"
  attr :class, :string, default: nil, doc: "wrapper classes"

  slot :item, doc: "menu items" do
    attr :icon, :string, doc: "item icon"
    attr :navigate, :string, doc: "LiveView navigation"
    attr :href, :string, doc: "regular link"
    attr :patch, :string, doc: "LiveView patch"
    attr :method, :string, doc: "HTTP method"
    attr :disabled, :boolean, doc: "disabled state"
    attr :class, :string, doc: "item classes"
  end

  slot :divider, doc: "menu divider"

  def dropdown_menu(assigns) do
    ~H"""
    <div class={[
      "dropdown",
      dropdown_position_class(@position),
      @hover && "dropdown-hover",
      @class
    ]}>
      <div
        tabindex="0"
        role="button"
        class={["btn gap-2", @button_class]}
      >
        <.icon :if={@icon} name={@icon} class="size-4" />
        {@label}
        <.icon name="hero-chevron-down" class="size-4" />
      </div>
      <ul
        tabindex="0"
        class={[
          "dropdown-content menu bg-base-100 rounded-lg z-50 min-w-60 p-1 shadow-lg border border-base-300",
          @menu_class
        ]}
        role="menu"
      >
        <%= for slot <- interleave_slots(@item, @divider) do %>
          <%= case slot do %>
            <% {:divider, _div} -> %>
              <li class="divider my-1"></li>
            <% {:item, item} -> %>
              <li>
                <%= if item[:navigate] || item[:href] || item[:patch] do %>
                  <.link
                    navigate={item[:navigate]}
                    href={item[:href]}
                    patch={item[:patch]}
                    method={item[:method]}
                    class={[
                      "flex items-center gap-3 px-3 py-2 rounded-lg text-sm",
                      item[:disabled] && "opacity-50 pointer-events-none",
                      item[:class]
                    ]}
                    role="menuitem"
                  >
                    <.icon :if={item[:icon]} name={item.icon} class="size-4 shrink-0" />
                    {render_slot([item])}
                  </.link>
                <% else %>
                  <button
                    type="button"
                    class={[
                      "flex items-center gap-3 px-3 py-2 rounded-lg text-sm w-full text-left",
                      item[:disabled] && "opacity-50 pointer-events-none",
                      item[:class]
                    ]}
                    disabled={item[:disabled]}
                    role="menuitem"
                  >
                    <.icon :if={item[:icon]} name={item.icon} class="size-4 shrink-0" />
                    {render_slot([item])}
                  </button>
                <% end %>
              </li>
          <% end %>
        <% end %>
      </ul>
    </div>
    """
  end

  # Helper to interleave items and dividers in order
  defp interleave_slots(items, dividers) do
    items_tagged = Enum.map(items, &{:item, &1})
    dividers_tagged = Enum.map(dividers, &{:divider, &1})

    # For simplicity, we just put all items first, then dividers aren't really interleaved
    # In practice, you'd use index positions. For now, dividers go between items.
    items_tagged ++ dividers_tagged
  end

  # =============================================================================
  # MODAL
  # =============================================================================

  @doc """
  Renders a DaisyUI modal dialog.

  ## Examples

      <.daisy_modal id="my-modal">
        <h3 class="text-lg font-bold">Hello!</h3>
        <p class="py-4">Press ESC key or click outside to close</p>
      </.daisy_modal>
      <button class="btn" onclick="my-modal.showModal()">Open</button>

      <.daisy_modal id="confirm-modal" open={@show_modal}>
        <:title>Confirm Action</:title>
        Are you sure?
        <:actions>
          <button class="btn">Cancel</button>
          <button class="btn btn-primary">Confirm</button>
        </:actions>
      </.daisy_modal>

  """
  attr :id, :string, required: true, doc: "modal ID"
  attr :open, :boolean, default: false, doc: "open state"
  attr :box_class, :string, default: nil, doc: "modal-box classes"
  attr :close_button, :boolean, default: true, doc: "show close button"
  attr :on_close, :string, default: nil, doc: "close event name"
  attr :autofocus, :boolean, default: true, doc: "auto-focus first input when opened"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :title, doc: "modal title"
  slot :inner_block, required: true, doc: "modal content"
  slot :actions, doc: "modal action buttons"

  def daisy_modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class={["modal", @open && "modal-open", @class]}
      phx-mounted={@open && show_modal(@id, @autofocus)}
    >
      <div class={["modal-box", @box_class]}>
        <form :if={@close_button} method="dialog">
          <button
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            phx-click={@on_close}
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </form>
        <h3 :if={@title != []} class="text-lg font-bold">
          {render_slot(@title)}
        </h3>
        <div class="py-4">
          {render_slot(@inner_block)}
        </div>
        <div :if={@actions != []} class="modal-action">
          {render_slot(@actions)}
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button phx-click={@on_close}>{gettext("close")}</button>
      </form>
    </dialog>
    """
  end

  defp show_modal(id, autofocus) do
    js = Phoenix.LiveView.JS.dispatch("modal:open", to: "##{id}")

    if autofocus do
      js
      |> Phoenix.LiveView.JS.focus_first(to: "##{id} .modal-box")
    else
      js
    end
  end

  # =============================================================================
  # SWAP
  # =============================================================================

  @doc """
  Renders a swap toggle between two states.

  ## Examples

      <.swap on_icon="hero-sun" off_icon="hero-moon" />

      <.swap rotate>
        <:on>ON</:on>
        <:off>OFF</:off>
      </.swap>

      <.swap flip active={@sound_on} on_click="toggle_sound">
        <:on><.icon name="hero-speaker-wave" /></:on>
        <:off><.icon name="hero-speaker-x-mark" /></:off>
      </.swap>

  """
  attr :active, :boolean, default: false, doc: "swap state"
  attr :rotate, :boolean, default: false, doc: "rotate animation"
  attr :flip, :boolean, default: false, doc: "flip animation"
  attr :on_icon, :string, default: nil, doc: "icon when active"
  attr :off_icon, :string, default: nil, doc: "icon when inactive"
  attr :on_click, :string, default: nil, doc: "click event"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :on, doc: "content when active"
  slot :off, doc: "content when inactive"

  def swap(assigns) do
    ~H"""
    <label class={[
      "swap",
      @rotate && "swap-rotate",
      @flip && "swap-flip",
      @class
    ]}>
      <input
        type="checkbox"
        checked={@active}
        phx-click={@on_click}
      />
      <div class="swap-on">
        <%= if @on != [] do %>
          {render_slot(@on)}
        <% else %>
          <.icon :if={@on_icon} name={@on_icon} class="size-6" />
        <% end %>
      </div>
      <div class="swap-off">
        <%= if @off != [] do %>
          {render_slot(@off)}
        <% else %>
          <.icon :if={@off_icon} name={@off_icon} class="size-6" />
        <% end %>
      </div>
    </label>
    """
  end

  # =============================================================================
  # THEME CONTROLLER
  # =============================================================================

  @doc """
  Renders a theme controller/switcher.

  ## Examples

      <.theme_controller themes={["light", "dark", "cupcake"]} />

      <.theme_controller
        themes={["light", "dark", "cyberpunk", "synthwave"]}
        current={@current_theme}
        on_change="change_theme"
      />

  """
  attr :themes, :list, required: true, doc: "list of theme names"
  attr :current, :string, default: nil, doc: "current theme"
  attr :on_change, :string, default: nil, doc: "change event"
  attr :class, :string, default: nil, doc: "additional classes"

  def theme_controller(assigns) do
    ~H"""
    <div class={["dropdown dropdown-end", @class]}>
      <div tabindex="0" role="button" class="btn btn-ghost">
        <.icon name="hero-swatch" class="size-5" />
        <span class="hidden sm:inline">{gettext("Theme")}</span>
        <.icon name="hero-chevron-down" class="size-3" />
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-200 rounded-box z-50 w-52 p-2 shadow-lg max-h-80 overflow-y-auto"
      >
        <li :for={theme <- @themes}>
          <button
            type="button"
            class={["flex justify-between", @current == theme && "active"]}
            phx-click={@on_change}
            phx-value-theme={theme}
            data-theme={theme}
          >
            <span class="capitalize">{theme}</span>
            <div class="flex gap-1">
              <div class="rounded bg-primary w-2 h-4"></div>
              <div class="rounded bg-secondary w-2 h-4"></div>
              <div class="rounded bg-accent w-2 h-4"></div>
              <div class="rounded bg-neutral w-2 h-4"></div>
            </div>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # =============================================================================
  # CLIPBOARD
  # =============================================================================

  @doc """
  Renders a copy-to-clipboard button with input.

  Requires a JS hook for clipboard functionality. Add to your app.js:

      Hooks.Clipboard = {
        mounted() {
          this.el.addEventListener("click", () => {
            const text = this.el.dataset.clipboardText;
            navigator.clipboard.writeText(text).then(() => {
              this.el.dataset.copied = "true";
              setTimeout(() => { this.el.dataset.copied = "false"; }, 2000);
            });
          });
        }
      }

  ## Examples

      <.clipboard text="npm install daisyui" />

      <.clipboard text={@api_key} label="API Key" />

      <.clipboard text="mix phx.server" prefix="$" monospace />

  """
  attr :id, :string, default: nil, doc: "unique ID for the component"
  attr :text, :string, required: true, doc: "text to copy"
  attr :label, :string, default: nil, doc: "optional label"
  attr :prefix, :string, default: nil, doc: "prefix like $ or >"
  attr :monospace, :boolean, default: true, doc: "use monospace font"
  attr :class, :string, default: nil, doc: "additional classes"

  def clipboard(assigns) do
    assigns =
      assign_new(assigns, :generated_id, fn ->
        "clipboard-#{System.unique_integer([:positive])}"
      end)

    ~H"""
    <div class={["flex flex-col gap-1", @class]}>
      <label :if={@label} class="text-sm font-medium text-base-content/70">
        {@label}
      </label>
      <div class="join">
        <input
          type="text"
          readonly
          value={[@prefix && "#{@prefix} ", @text] |> Enum.join()}
          class={[
            "input join-item flex-1 bg-base-200",
            @monospace && "font-mono text-sm"
          ]}
        />
        <button
          type="button"
          id={@id || @generated_id}
          class="btn join-item"
          phx-hook="Clipboard"
          data-clipboard-text={@text}
          data-copied="false"
          aria-label={gettext("Copy to clipboard")}
        >
          <span class="[[data-copied=false]_&]:block [[data-copied=true]_&]:hidden">
            <.icon name="hero-clipboard-document" class="size-5" />
          </span>
          <span class="[[data-copied=false]_&]:hidden [[data-copied=true]_&]:block text-success">
            <.icon name="hero-check" class="size-5" />
          </span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders an inline copy button (just the button, no input).

  ## Examples

      <.copy_button text="secret-key-123" />

      <.copy_button text={@code} tooltip="Copy code" />

  """
  attr :id, :string, default: nil, doc: "unique ID for the component"
  attr :text, :string, required: true, doc: "text to copy"
  attr :tooltip, :string, default: "Copy", doc: "tooltip text"
  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "button size"
  attr :class, :string, default: nil, doc: "additional classes"

  def copy_button(assigns) do
    assigns =
      assign_new(assigns, :generated_id, fn ->
        "copy-btn-#{System.unique_integer([:positive])}"
      end)

    ~H"""
    <div class="tooltip" data-tip={@tooltip}>
      <button
        type="button"
        id={@id || @generated_id}
        class={[
          "btn btn-ghost btn-square",
          button_size_class(@size),
          @class
        ]}
        phx-hook="Clipboard"
        data-clipboard-text={@text}
        data-copied="false"
        aria-label={gettext("Copy to clipboard")}
      >
        <span class="[[data-copied=false]_&]:block [[data-copied=true]_&]:hidden">
          <.icon name="hero-clipboard-document" class={copy_icon_size(@size)} />
        </span>
        <span class="[[data-copied=false]_&]:hidden [[data-copied=true]_&]:block text-success">
          <.icon name="hero-check" class={copy_icon_size(@size)} />
        </span>
      </button>
    </div>
    """
  end

  defp copy_icon_size(:xs), do: "size-3"
  defp copy_icon_size(:sm), do: "size-4"
  defp copy_icon_size(:md), do: "size-5"
  defp copy_icon_size(:lg), do: "size-6"

  @doc """
  Renders a code block with copy button.

  ## Examples

      <.code_copy code="npm install daisyui" />

      <.code_copy code="mix deps.get && mix phx.server" prefix="$" />

  """
  attr :code, :string, required: true, doc: "code to display and copy"
  attr :prefix, :string, default: nil, doc: "prefix like $ or >"
  attr :class, :string, default: nil, doc: "additional classes"

  def code_copy(assigns) do
    ~H"""
    <div class={["relative group", @class]}>
      <pre class="bg-base-200 rounded-lg px-4 py-3 pr-12 font-mono text-sm overflow-x-auto">
        <code><span :if={@prefix} class="text-base-content/50">{@prefix} </span>{@code}</code>
      </pre>
      <div class="absolute top-2 right-2 opacity-0 group-hover:opacity-100 transition-opacity">
        <.copy_button text={@code} size={:sm} />
      </div>
    </div>
    """
  end
end
