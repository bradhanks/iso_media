defmodule PerfectPaperWeb.DaisyFeedbackComponents do
  @moduledoc """
  DaisyUI Feedback Components.

  Provides feedback-related components following DaisyUI's component structure:
  - `alert/1` - Alert/notification boxes
  - `loading/1` - Spinners and loading indicators
  - `progress/1` - Progress bars
  - `radial_progress/1` - Circular progress indicators
  - `skeleton_text/1`, `skeleton_card/1` - Loading placeholders
  - `toast/1` - Positioned notifications
  - `tooltip/1` - Hover hints

  See https://daisyui.com/components/ for reference.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  # =============================================================================
  # ALERT
  # =============================================================================

  @doc """
  Renders an alert/notification box.

  ## Examples

      <.alert type={:info} message="Your changes have been saved." />

      <.alert type={:warning}>
        <:title>Attention</:title>
        Please review your settings before continuing.
      </.alert>

      <.alert type={:error} message="Failed to save changes." />

      <.alert type={:success} dismissible on_dismiss="dismiss_alert">
        Operation completed successfully!
      </.alert>

  """
  attr :type, :atom,
    default: :info,
    values: [:info, :success, :warning, :error],
    doc: "alert type determines color and icon"

  attr :message, :string, default: nil, doc: "alert message (alternative to inner_block)"
  attr :class, :string, default: nil, doc: "additional CSS classes"
  attr :dismissible, :boolean, default: false, doc: "show close button"
  attr :on_dismiss, :string, default: nil, doc: "event name for dismiss (required if dismissible)"
  attr :rest, :global

  slot :title, doc: "optional bold title (can contain icons/markup)"
  slot :inner_block, doc: "alert content (alternative to message attr)"

  def alert(assigns) do
    icon_name =
      case assigns.type do
        :info -> "hero-information-circle"
        :success -> "hero-check-circle"
        :warning -> "hero-exclamation-triangle"
        :error -> "hero-exclamation-circle"
      end

    alert_class =
      case assigns.type do
        :info -> "alert-info"
        :success -> "alert-success"
        :warning -> "alert-warning"
        :error -> "alert-error"
      end

    assigns =
      assigns
      |> assign(:icon_name, icon_name)
      |> assign(:alert_class, alert_class)

    ~H"""
    <div class={["alert", @alert_class, @class]} role="alert" {@rest}>
      <.icon name={@icon_name} class="size-5 shrink-0" />
      <div class="flex-1">
        <p :if={@title != []} class="font-medium">{render_slot(@title)}</p>
        <p :if={@message}>{@message}</p>
        {render_slot(@inner_block)}
      </div>
      <button
        :if={@dismissible && @on_dismiss}
        type="button"
        class="btn btn-ghost btn-sm btn-circle"
        phx-click={@on_dismiss}
        aria-label={gettext("Dismiss")}
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  # =============================================================================
  # LOADING
  # =============================================================================

  @doc """
  Renders a loading indicator.

  ## Examples

      <.loading />
      <.loading type={:dots} size={:lg} />
      <.loading type={:ring} color={:primary} />
      <.loading type={:bars} />

  """
  attr :type, :atom,
    default: :spinner,
    values: [:spinner, :dots, :ring, :ball, :bars, :infinity],
    doc: "loading indicator type"

  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "indicator size"

  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent, :neutral, :info, :success, :warning, :error],
    doc: "indicator color"

  attr :class, :string, default: nil, doc: "additional classes"

  def loading(assigns) do
    ~H"""
    <span
      class={[
        "loading",
        loading_type_class(@type),
        loading_size_class(@size),
        loading_color_class(@color),
        @class
      ]}
      aria-label={gettext("Loading")}
    />
    """
  end

  defp loading_type_class(:spinner), do: "loading-spinner"
  defp loading_type_class(:dots), do: "loading-dots"
  defp loading_type_class(:ring), do: "loading-ring"
  defp loading_type_class(:ball), do: "loading-ball"
  defp loading_type_class(:bars), do: "loading-bars"
  defp loading_type_class(:infinity), do: "loading-infinity"

  defp loading_size_class(:xs), do: "loading-xs"
  defp loading_size_class(:sm), do: "loading-sm"
  defp loading_size_class(:md), do: "loading-md"
  defp loading_size_class(:lg), do: "loading-lg"

  defp loading_color_class(nil), do: nil
  defp loading_color_class(:primary), do: "text-primary"
  defp loading_color_class(:secondary), do: "text-secondary"
  defp loading_color_class(:accent), do: "text-accent"
  defp loading_color_class(:neutral), do: "text-neutral"
  defp loading_color_class(:info), do: "text-info"
  defp loading_color_class(:success), do: "text-success"
  defp loading_color_class(:warning), do: "text-warning"
  defp loading_color_class(:error), do: "text-error"

  # =============================================================================
  # PROGRESS
  # =============================================================================

  @doc """
  Renders a progress bar.

  ## Examples

      <.progress value={40} />
      <.progress value={70} max={100} color={:primary} />
      <.progress />  <!-- Indeterminate -->

  """
  attr :value, :integer, default: nil, doc: "current value (nil for indeterminate)"
  attr :max, :integer, default: 100, doc: "maximum value"

  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent, :info, :success, :warning, :error],
    doc: "progress color"

  attr :class, :string, default: nil, doc: "additional classes"

  def progress(assigns) do
    ~H"""
    <progress
      class={[
        "progress w-full",
        progress_color_class(@color),
        @class
      ]}
      value={@value}
      max={@max}
      aria-valuenow={@value}
      aria-valuemax={@max}
    />
    """
  end

  defp progress_color_class(nil), do: nil
  defp progress_color_class(:primary), do: "progress-primary"
  defp progress_color_class(:secondary), do: "progress-secondary"
  defp progress_color_class(:accent), do: "progress-accent"
  defp progress_color_class(:info), do: "progress-info"
  defp progress_color_class(:success), do: "progress-success"
  defp progress_color_class(:warning), do: "progress-warning"
  defp progress_color_class(:error), do: "progress-error"

  # =============================================================================
  # RADIAL PROGRESS
  # =============================================================================

  @doc """
  Renders a radial/circular progress indicator.

  ## Examples

      <.radial_progress value={70} />
      <.radial_progress value={45} size="4rem" thickness="4px" color={:primary}>
        45%
      </.radial_progress>

  """
  attr :value, :integer, required: true, doc: "progress value (0-100)"
  attr :size, :string, default: "5rem", doc: "size (CSS value)"
  attr :thickness, :string, default: "0.25rem", doc: "border thickness"

  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent, :info, :success, :warning, :error],
    doc: "progress color"

  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, doc: "content to display in center (defaults to percentage)"

  def radial_progress(assigns) do
    ~H"""
    <div
      class={[
        "radial-progress",
        radial_progress_color_class(@color),
        @class
      ]}
      style={"--value:#{@value}; --size:#{@size}; --thickness:#{@thickness};"}
      role="progressbar"
      aria-valuenow={@value}
      aria-valuemin="0"
      aria-valuemax="100"
    >
      <%= if @inner_block == [] do %>
        {@value}%
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </div>
    """
  end

  defp radial_progress_color_class(nil), do: nil
  defp radial_progress_color_class(:primary), do: "text-primary"
  defp radial_progress_color_class(:secondary), do: "text-secondary"
  defp radial_progress_color_class(:accent), do: "text-accent"
  defp radial_progress_color_class(:info), do: "text-info"
  defp radial_progress_color_class(:success), do: "text-success"
  defp radial_progress_color_class(:warning), do: "text-warning"
  defp radial_progress_color_class(:error), do: "text-error"

  # =============================================================================
  # SKELETON
  # =============================================================================

  @doc """
  Renders a skeleton text block (multiple lines).

  ## Examples

      <.skeleton_text lines={3} />
      <.skeleton_text lines={2} class="gap-2" />

  """
  attr :lines, :integer, default: 3, doc: "number of lines"
  attr :class, :string, default: nil, doc: "additional classes for container"

  def skeleton_text(assigns) do
    ~H"""
    <div class={["flex flex-col gap-4", @class]}>
      <div
        :for={i <- 1..@lines}
        class={[
          "skeleton h-4",
          (i == @lines && "w-3/4") || "w-full"
        ]}
      />
    </div>
    """
  end

  @doc """
  Renders a skeleton card placeholder.

  ## Examples

      <.skeleton_card />
      <.skeleton_card image />

  """
  attr :image, :boolean, default: false, doc: "include image placeholder"
  attr :class, :string, default: nil, doc: "additional classes"

  def skeleton_card(assigns) do
    ~H"""
    <div class={["flex flex-col gap-4 w-full", @class]}>
      <div :if={@image} class="skeleton h-32 w-full" />
      <div class="skeleton h-4 w-28" />
      <div class="skeleton h-4 w-full" />
      <div class="skeleton h-4 w-full" />
    </div>
    """
  end

  # =============================================================================
  # TOAST
  # =============================================================================

  @doc """
  Renders a toast container for positioned notifications.

  ## Examples

      <.toast>
        <.alert type={:info}>New message received</.alert>
      </.toast>

      <.toast position={:top_end}>
        <.alert type={:success}>Saved!</.alert>
      </.toast>

  """
  attr :position, :atom,
    default: :bottom_end,
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
    doc: "toast position"

  attr :class, :string, default: nil, doc: "additional classes"
  slot :inner_block, required: true

  def toast(assigns) do
    ~H"""
    <div class={[
      "toast",
      toast_position_class(@position),
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp toast_position_class(:top_start), do: "toast-top toast-start"
  defp toast_position_class(:top_center), do: "toast-top toast-center"
  defp toast_position_class(:top_end), do: "toast-top toast-end"
  defp toast_position_class(:middle_start), do: "toast-middle toast-start"
  defp toast_position_class(:middle_center), do: "toast-middle toast-center"
  defp toast_position_class(:middle_end), do: "toast-middle toast-end"
  defp toast_position_class(:bottom_start), do: "toast-bottom toast-start"
  defp toast_position_class(:bottom_center), do: "toast-bottom toast-center"
  defp toast_position_class(:bottom_end), do: "toast-bottom toast-end"

  # =============================================================================
  # TOOLTIP
  # =============================================================================

  @doc """
  Renders a tooltip wrapper.

  ## Examples

      <.tooltip tip="This is helpful text">
        <button class="btn">Hover me</button>
      </.tooltip>

      <.tooltip tip="Opens settings" position={:left} color={:primary}>
        <.icon name="hero-cog-6-tooth" />
      </.tooltip>

  """
  attr :tip, :string, required: true, doc: "tooltip text"

  attr :position, :atom,
    default: :top,
    values: [:top, :bottom, :left, :right],
    doc: "tooltip position"

  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent, :info, :success, :warning, :error],
    doc: "tooltip color"

  attr :open, :boolean, default: false, doc: "force tooltip open"
  attr :class, :string, default: nil, doc: "additional classes"

  slot :inner_block, required: true

  def tooltip(assigns) do
    ~H"""
    <div
      class={[
        "tooltip",
        tooltip_position_class(@position),
        tooltip_color_class(@color),
        @open && "tooltip-open",
        @class
      ]}
      data-tip={@tip}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp tooltip_position_class(:top), do: nil
  defp tooltip_position_class(:bottom), do: "tooltip-bottom"
  defp tooltip_position_class(:left), do: "tooltip-left"
  defp tooltip_position_class(:right), do: "tooltip-right"

  defp tooltip_color_class(nil), do: nil
  defp tooltip_color_class(:primary), do: "tooltip-primary"
  defp tooltip_color_class(:secondary), do: "tooltip-secondary"
  defp tooltip_color_class(:accent), do: "tooltip-accent"
  defp tooltip_color_class(:info), do: "tooltip-info"
  defp tooltip_color_class(:success), do: "tooltip-success"
  defp tooltip_color_class(:warning), do: "tooltip-warning"
  defp tooltip_color_class(:error), do: "tooltip-error"
end
