defmodule PerfectPaperWeb.DaisyMockupComponents do
  @moduledoc """
  DaisyUI Mockup Components.

  Provides mockup/frame components following DaisyUI's component structure:
  - Browser (browser window frame)
  - Code (code editor frame)
  - Phone (mobile device frame)
  - Window (desktop window frame)

  See https://daisyui.com/components/ for reference.
  """
  use Phoenix.Component

  # =============================================================================
  # MOCKUP BROWSER
  # =============================================================================

  @doc """
  Renders a browser window mockup.

  ## Examples

      <.mockup_browser url="https://perfectpaper.ink">
        <p>Page content here</p>
      </.mockup_browser>

      <.mockup_browser url="https://daisyui.com" class="border border-base-300">
        <div class="p-4">Browser content</div>
      </.mockup_browser>

  """
  attr :url, :string, default: "https://perfectpaper.ink", doc: "URL to display in address bar"
  attr :class, :string, default: nil, doc: "additional classes for wrapper"
  attr :content_class, :string, default: nil, doc: "additional classes for content area"

  slot :inner_block, required: true

  def mockup_browser(assigns) do
    ~H"""
    <div class={["mockup-browser bg-base-300", @class]}>
      <div class="mockup-browser-toolbar">
        <div class="input">{@url}</div>
      </div>
      <div class={["bg-base-200", @content_class]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # =============================================================================
  # MOCKUP CODE
  # =============================================================================

  @doc """
  Renders a code editor mockup.

  ## Examples

      <.mockup_code>
        <:line>npm install daisyui</:line>
      </.mockup_code>

      <.mockup_code>
        <:line prefix="$">npm install</:line>
        <:line prefix=">" class="text-warning">installing...</:line>
        <:line prefix=">" class="text-success">Done!</:line>
      </.mockup_code>

  """
  attr :class, :string, default: nil, doc: "additional classes"

  slot :line, required: true, doc: "code lines" do
    attr :prefix, :string, doc: "line prefix (e.g., $, >, 1)"
    attr :class, :string, doc: "line-specific classes"
  end

  def mockup_code(assigns) do
    ~H"""
    <div class={["mockup-code", @class]}>
      <pre :for={line <- @line} data-prefix={line[:prefix] || "$"}>
        <code class={line[:class]}>{render_slot([line])}</code>
      </pre>
    </div>
    """
  end

  @doc """
  Renders a simple code block (single content area).

  ## Examples

      <.mockup_code_block language="elixir">
        defmodule Hello do
          def world, do: "Hello, World!"
        end
      </.mockup_code_block>

  """
  attr :language, :string, default: nil, doc: "programming language for syntax class"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, required: true

  def mockup_code_block(assigns) do
    ~H"""
    <div class={["mockup-code", @class]}>
      <pre><code class={@language && "language-#{@language}"}>{render_slot(@inner_block)}</code></pre>
    </div>
    """
  end

  # =============================================================================
  # MOCKUP PHONE
  # =============================================================================

  @doc """
  Renders a mobile phone mockup.

  ## Examples

      <.mockup_phone>
        <img src="/screenshot.png" alt="App screenshot" />
      </.mockup_phone>

      <.mockup_phone color={:primary}>
        <div class="p-4 bg-base-100 h-full">
          <p>Phone content</p>
        </div>
      </.mockup_phone>

  """
  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent],
    doc: "phone frame color"

  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, required: true

  def mockup_phone(assigns) do
    ~H"""
    <div class={[
      "mockup-phone",
      phone_color_class(@color),
      @class
    ]}>
      <div class="camera"></div>
      <div class="display">
        <div class="artboard artboard-demo phone-1">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  defp phone_color_class(nil), do: nil
  defp phone_color_class(:primary), do: "border-primary"
  defp phone_color_class(:secondary), do: "border-secondary"
  defp phone_color_class(:accent), do: "border-accent"

  # =============================================================================
  # MOCKUP WINDOW
  # =============================================================================

  @doc """
  Renders a desktop window mockup.

  ## Examples

      <.mockup_window>
        <p>Window content</p>
      </.mockup_window>

      <.mockup_window class="border border-base-300">
        <div class="p-8 bg-base-200">
          Desktop application content
        </div>
      </.mockup_window>

  """
  attr :class, :string, default: nil, doc: "additional classes"
  attr :content_class, :string, default: nil, doc: "content area classes"

  slot :inner_block, required: true

  def mockup_window(assigns) do
    ~H"""
    <div class={["mockup-window bg-base-300", @class]}>
      <div class={["bg-base-200", @content_class]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
