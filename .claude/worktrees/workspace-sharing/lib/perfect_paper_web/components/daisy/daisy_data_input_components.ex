defmodule PerfectPaperWeb.DaisyDataInputComponents do
  @moduledoc """
  DaisyUI Data Input Components.

  Provides data input components following DaisyUI's component structure:
  - File Input (simple file upload)
  - File Upload (advanced drag & drop with preview)
  - Document Upload (multi-file with progress tracking)
  - Range
  - Rating
  - Toggle

  Note: Basic inputs like text, select, textarea, checkbox, and radio are
  provided by CoreComponents. These components provide enhanced functionality
  and DaisyUI-specific styling.

  See https://daisyui.com/components/ for reference.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  # =============================================================================
  # FILE INPUT (Simple)
  # =============================================================================

  @doc """
  Renders a simple DaisyUI file input.

  ## Examples

      <.file_input name="avatar" />

      <.file_input name="document" accept=".pdf,.doc" color={:primary} />

      <.file_input name="images" accept="image/*" multiple />

  """
  attr :name, :string, required: true, doc: "input name"
  attr :accept, :string, default: nil, doc: "accepted file types"
  attr :multiple, :boolean, default: false, doc: "allow multiple files"
  attr :disabled, :boolean, default: false, doc: "disabled state"
  attr :required, :boolean, default: false, doc: "required field"

  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent, :info, :success, :warning, :error],
    doc: "input color"

  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg, :xl], doc: "input size"
  attr :ghost, :boolean, default: false, doc: "ghost style (no background)"
  attr :class, :string, default: nil, doc: "additional classes"
  attr :rest, :global

  def file_input(assigns) do
    ~H"""
    <input
      type="file"
      name={@name}
      accept={@accept}
      multiple={@multiple}
      disabled={@disabled}
      required={@required}
      class={[
        "file-input w-full",
        @ghost && "file-input-ghost",
        file_color_class(@color),
        file_size_class(@size),
        @class
      ]}
      {@rest}
    />
    """
  end

  defp file_color_class(nil), do: nil
  defp file_color_class(:primary), do: "file-input-primary"
  defp file_color_class(:secondary), do: "file-input-secondary"
  defp file_color_class(:accent), do: "file-input-accent"
  defp file_color_class(:info), do: "file-input-info"
  defp file_color_class(:success), do: "file-input-success"
  defp file_color_class(:warning), do: "file-input-warning"
  defp file_color_class(:error), do: "file-input-error"

  defp file_size_class(:xs), do: "file-input-xs"
  defp file_size_class(:sm), do: "file-input-sm"
  defp file_size_class(:md), do: nil
  defp file_size_class(:lg), do: "file-input-lg"
  defp file_size_class(:xl), do: "file-input-xl"

  # =============================================================================
  # FILE UPLOAD (Drag & Drop with Preview)
  # =============================================================================

  @doc """
  Renders a drag-and-drop file upload zone with preview.

  Ideal for single-file uploads like profile pictures, watermarks, logos.

  This component requires the `phx-drop-target` attribute to work with
  Phoenix LiveView file uploads. Configure uploads in your LiveView:

      def mount(_params, _session, socket) do
        {:ok, allow_upload(socket, :avatar, accept: ~w(.jpg .jpeg .png), max_entries: 1, max_file_size: 5_242_880)}
      end

  ## Examples

      <.file_upload upload={@uploads.avatar} />

      <.file_upload
        upload={@uploads.avatar}
        label="Profile Photo"
        description="JPG, PNG up to 5MB"
        preview_type={:image}
      />

      <.file_upload
        upload={@uploads.watermark}
        label="Draft Watermark"
        description="PNG with transparency recommended"
        preview_type={:image}
        shape={:square}
      />

  """
  attr :upload, :any, required: true, doc: "Phoenix LiveView upload config"
  attr :label, :string, default: "Upload a file", doc: "main label text"
  attr :description, :string, default: "or drag and drop", doc: "description text"
  attr :hint, :string, default: nil, doc: "hint text below (e.g., file size limit)"
  attr :preview_type, :atom, default: :image, values: [:image, :icon, :none], doc: "preview style"

  attr :shape, :atom,
    default: :landscape,
    values: [:landscape, :square, :circle],
    doc: "upload zone shape"

  attr :class, :string, default: nil, doc: "additional classes"

  def file_upload(assigns) do
    ~H"""
    <div class={["w-full", @class]}>
      <div
        class={[
          "relative border-2 border-dashed border-base-300 rounded-lg transition-colors",
          "hover:border-primary/50 hover:bg-base-200/50",
          "focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20",
          shape_classes(@shape)
        ]}
        phx-drop-target={@upload.ref}
      >
        <%= if Enum.empty?(@upload.entries) do %>
          <label class="flex flex-col items-center justify-center w-full h-full cursor-pointer p-6">
            <div class="flex flex-col items-center justify-center text-center">
              <.icon name="hero-cloud-arrow-up" class="size-10 text-base-content/40 mb-3" />
              <p class="text-sm font-medium text-base-content">{@label}</p>
              <p class="text-xs text-base-content/60 mt-1">{@description}</p>
              <p :if={@hint} class="text-xs text-base-content/40 mt-2">{@hint}</p>
            </div>
            <.live_file_input upload={@upload} class="hidden" />
          </label>
        <% else %>
          <%= for entry <- @upload.entries do %>
            <div class="relative w-full h-full">
              <%= if @preview_type == :image do %>
                <.live_img_preview
                  entry={entry}
                  class={[
                    "object-cover w-full h-full",
                    @shape == :circle && "rounded-full"
                  ]}
                />
              <% else %>
                <div class="flex flex-col items-center justify-center w-full h-full p-6">
                  <.icon name="hero-document" class="size-12 text-base-content/40 mb-2" />
                  <p class="text-sm font-medium text-base-content truncate max-w-full px-4">
                    {entry.client_name}
                  </p>
                  <p class="text-xs text-base-content/60 mt-1">
                    {format_bytes(entry.client_size)}
                  </p>
                </div>
              <% end %>

              <%!-- Progress bar overlay --%>
              <div
                :if={entry.progress > 0 && entry.progress < 100}
                class="absolute inset-x-0 bottom-0 bg-base-100/80 px-3 py-2"
              >
                <div class="flex items-center gap-2">
                  <progress class="progress progress-primary flex-1" value={entry.progress} max="100" />
                  <span class="text-xs font-medium">{entry.progress}%</span>
                </div>
              </div>

              <%!-- Remove button --%>
              <button
                type="button"
                class="absolute top-2 right-2 btn btn-circle btn-sm btn-error"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                aria-label={gettext("Remove file")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>

              <%!-- Error display --%>
              <%= for err <- upload_errors(@upload, entry) do %>
                <div class="absolute inset-x-0 bottom-0 bg-error/90 text-error-content px-3 py-2 text-sm">
                  {error_to_string(err)}
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>

      <%!-- General upload errors --%>
      <%= for err <- upload_errors(@upload) do %>
        <p class="text-error text-sm mt-2 flex items-center gap-1">
          <.icon name="hero-exclamation-circle" class="size-4" />
          {error_to_string(err)}
        </p>
      <% end %>
    </div>
    """
  end

  defp shape_classes(:landscape), do: "aspect-video min-h-[160px]"
  defp shape_classes(:square), do: "aspect-square max-w-[200px]"
  defp shape_classes(:circle), do: "aspect-square max-w-[200px] rounded-full"

  # =============================================================================
  # DOCUMENT UPLOAD (Multi-file with Progress)
  # =============================================================================

  @doc """
  Renders a multi-file document upload area with detailed progress tracking.

  Ideal for uploading manuscripts, documents, and other files that need
  progress indicators and file type icons.

  ## Examples

      <.document_upload upload={@uploads.documents} />

      <.document_upload
        upload={@uploads.documents}
        label="Upload manuscript"
        description="PDF or image files of your manuscript files"
        show_file_list
      />

  """
  attr :upload, :any, required: true, doc: "Phoenix LiveView upload config"
  attr :label, :string, default: "Upload files", doc: "main label text"
  attr :description, :string, default: nil, doc: "description text"
  attr :show_file_list, :boolean, default: true, doc: "show uploaded file list"
  attr :compact, :boolean, default: false, doc: "compact upload zone"
  attr :class, :string, default: nil, doc: "additional classes"

  def document_upload(assigns) do
    ~H"""
    <div class={["w-full", @class]}>
      <%!-- Upload Zone --%>
      <div
        class={[
          "border-2 border-dashed border-base-300 rounded-lg transition-colors",
          "hover:border-primary/50 hover:bg-base-200/50",
          "focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20"
        ]}
        phx-drop-target={@upload.ref}
      >
        <label class={[
          "flex items-center cursor-pointer",
          @compact && "p-4 gap-4",
          !@compact && "flex-col justify-center p-8"
        ]}>
          <div class={[
            "rounded-full bg-base-200 flex items-center justify-center",
            @compact && "size-12",
            !@compact && "size-16 mb-4"
          ]}>
            <.icon
              name="hero-arrow-up-tray"
              class={[@compact && "size-6", !@compact && "size-8", "text-primary"]}
            />
          </div>
          <div class={[@compact && "flex-1", !@compact && "text-center"]}>
            <p class="font-medium text-base-content">{@label}</p>
            <p :if={@description} class="text-sm text-base-content/60 mt-1">{@description}</p>
            <p class="text-xs text-base-content/40 mt-1">
              {gettext("Max file size: %{size}", size: format_max_size(@upload))}
            </p>
          </div>
          <div class={[@compact && "btn btn-primary btn-sm", !@compact && "btn btn-primary mt-4"]}>
            <.icon name="hero-plus" class="size-4" />
            {gettext("Choose files")}
          </div>
          <.live_file_input upload={@upload} class="hidden" />
        </label>
      </div>

      <%!-- General upload errors --%>
      <%= for err <- upload_errors(@upload) do %>
        <div class="alert alert-error mt-3">
          <.icon name="hero-exclamation-circle" class="size-5" />
          <span>{error_to_string(err)}</span>
        </div>
      <% end %>

      <%!-- File List --%>
      <div :if={@show_file_list && @upload.entries != []} class="mt-4 space-y-2">
        <%= for entry <- @upload.entries do %>
          <.upload_file_item entry={entry} upload={@upload} />
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a single file item in an upload list.
  """
  attr :entry, :any, required: true, doc: "upload entry"
  attr :upload, :any, required: true, doc: "parent upload config"

  def upload_file_item(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-3 p-3 rounded-lg",
      "bg-base-200/50 border border-base-300",
      upload_errors(@upload, @entry) != [] && "border-error bg-error/5"
    ]}>
      <%!-- File Icon/Preview --%>
      <div class="shrink-0">
        <%= if image_entry?(@entry) do %>
          <.live_img_preview entry={@entry} class="size-12 rounded-lg object-cover" />
        <% else %>
          <div class="size-12 rounded-lg bg-base-300 flex items-center justify-center">
            <.icon name={file_type_icon(@entry.client_name)} class="size-6 text-base-content/60" />
          </div>
        <% end %>
      </div>

      <%!-- File Info --%>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-medium truncate">{@entry.client_name}</p>
        <div class="flex items-center gap-2 mt-1">
          <span class="text-xs text-base-content/60">{format_bytes(@entry.client_size)}</span>
          <%= if @entry.progress > 0 && @entry.progress < 100 do %>
            <span class="text-xs text-primary">{@entry.progress}%</span>
          <% end %>
          <%= if @entry.progress == 100 do %>
            <span class="text-xs text-success flex items-center gap-1">
              <.icon name="hero-check-circle" class="size-3" />
              {gettext("Complete")}
            </span>
          <% end %>
        </div>

        <%!-- Progress Bar --%>
        <progress
          :if={@entry.progress > 0 && @entry.progress < 100}
          class="progress progress-primary h-1 w-full mt-2"
          value={@entry.progress}
          max="100"
        />

        <%!-- Errors --%>
        <%= for err <- upload_errors(@upload, @entry) do %>
          <p class="text-xs text-error mt-1 flex items-center gap-1">
            <.icon name="hero-exclamation-circle" class="size-3" />
            {error_to_string(err)}
          </p>
        <% end %>
      </div>

      <%!-- Actions --%>
      <div class="shrink-0 flex items-center gap-1">
        <%= if @entry.progress == 100 do %>
          <button
            type="button"
            class="btn btn-ghost btn-circle btn-sm text-success"
            aria-label={gettext("Upload complete")}
          >
            <.icon name="hero-check" class="size-5" />
          </button>
        <% end %>
        <button
          type="button"
          class="btn btn-ghost btn-circle btn-sm hover:btn-error"
          phx-click="cancel-upload"
          phx-value-ref={@entry.ref}
          aria-label={gettext("Remove file")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  # =============================================================================
  # RANGE
  # =============================================================================

  @doc """
  Renders a DaisyUI range slider.

  ## Examples

      <.range name="volume" min={0} max={100} value={50} />

      <.range name="quality" min={1} max={5} step={1} color={:primary} />

  """
  attr :name, :string, required: true, doc: "input name"
  attr :value, :integer, default: 0, doc: "current value"
  attr :min, :integer, default: 0, doc: "minimum value"
  attr :max, :integer, default: 100, doc: "maximum value"
  attr :step, :integer, default: 1, doc: "step increment"
  attr :disabled, :boolean, default: false, doc: "disabled state"

  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent, :info, :success, :warning, :error],
    doc: "range color"

  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "range size"
  attr :class, :string, default: nil, doc: "additional classes"
  attr :rest, :global

  def range(assigns) do
    ~H"""
    <input
      type="range"
      name={@name}
      value={@value}
      min={@min}
      max={@max}
      step={@step}
      disabled={@disabled}
      class={[
        "range",
        range_color_class(@color),
        range_size_class(@size),
        @class
      ]}
      {@rest}
    />
    """
  end

  defp range_color_class(nil), do: nil
  defp range_color_class(:primary), do: "range-primary"
  defp range_color_class(:secondary), do: "range-secondary"
  defp range_color_class(:accent), do: "range-accent"
  defp range_color_class(:info), do: "range-info"
  defp range_color_class(:success), do: "range-success"
  defp range_color_class(:warning), do: "range-warning"
  defp range_color_class(:error), do: "range-error"

  defp range_size_class(:xs), do: "range-xs"
  defp range_size_class(:sm), do: "range-sm"
  defp range_size_class(:md), do: nil
  defp range_size_class(:lg), do: "range-lg"

  # =============================================================================
  # RATING
  # =============================================================================

  @doc """
  Renders a DaisyUI star rating input.

  ## Examples

      <.rating name="score" value={3} />

      <.rating name="quality" value={4} max={5} color={:warning} size={:lg} />

      <.rating name="feedback" value={@rating} half />

  """
  attr :name, :string, required: true, doc: "input name"
  attr :value, :integer, default: 0, doc: "current rating value"
  attr :max, :integer, default: 5, doc: "maximum stars"
  attr :half, :boolean, default: false, doc: "allow half-star ratings"
  attr :disabled, :boolean, default: false, doc: "disabled state"
  attr :hidden_zero, :boolean, default: true, doc: "include hidden zero option for clearing"

  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent, :info, :success, :warning, :error],
    doc: "star color"

  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "rating size"
  attr :class, :string, default: nil, doc: "additional classes"
  attr :rest, :global

  def rating(assigns) do
    ~H"""
    <div class={[
      "rating",
      @half && "rating-half",
      rating_size_class(@size),
      @class
    ]}>
      <input
        :if={@hidden_zero}
        type="radio"
        name={@name}
        value="0"
        class="rating-hidden"
        checked={@value == 0}
        disabled={@disabled}
      />
      <%= for i <- 1..@max do %>
        <%= if @half do %>
          <input
            type="radio"
            name={@name}
            value={i - 0.5}
            class={["mask mask-star-2 mask-half-1", rating_color_class(@color)]}
            checked={@value == i - 0.5}
            disabled={@disabled}
            {@rest}
          />
          <input
            type="radio"
            name={@name}
            value={i}
            class={["mask mask-star-2 mask-half-2", rating_color_class(@color)]}
            checked={@value == i}
            disabled={@disabled}
            {@rest}
          />
        <% else %>
          <input
            type="radio"
            name={@name}
            value={i}
            class={["mask mask-star-2", rating_color_class(@color)]}
            checked={@value == i}
            disabled={@disabled}
            {@rest}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp rating_color_class(nil), do: "bg-warning"
  defp rating_color_class(:primary), do: "bg-primary"
  defp rating_color_class(:secondary), do: "bg-secondary"
  defp rating_color_class(:accent), do: "bg-accent"
  defp rating_color_class(:info), do: "bg-info"
  defp rating_color_class(:success), do: "bg-success"
  defp rating_color_class(:warning), do: "bg-warning"
  defp rating_color_class(:error), do: "bg-error"

  defp rating_size_class(:xs), do: "rating-xs"
  defp rating_size_class(:sm), do: "rating-sm"
  defp rating_size_class(:md), do: nil
  defp rating_size_class(:lg), do: "rating-lg"

  # =============================================================================
  # TOGGLE
  # =============================================================================

  @doc """
  Renders a DaisyUI toggle switch.

  ## Examples

      <.toggle name="notifications" />

      <.toggle name="dark_mode" checked={@dark_mode} color={:primary} />

      <.toggle name="feature" label="Enable feature" />

  """
  attr :name, :string, required: true, doc: "input name"
  attr :checked, :boolean, default: false, doc: "checked state"
  attr :disabled, :boolean, default: false, doc: "disabled state"
  attr :label, :string, default: nil, doc: "optional label"

  attr :color, :atom,
    default: nil,
    values: [nil, :primary, :secondary, :accent, :info, :success, :warning, :error],
    doc: "toggle color"

  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg], doc: "toggle size"
  attr :class, :string, default: nil, doc: "additional classes"
  attr :rest, :global

  def toggle(assigns) do
    ~H"""
    <label class={["flex items-center gap-3 cursor-pointer", @class]}>
      <input
        type="checkbox"
        name={@name}
        checked={@checked}
        disabled={@disabled}
        class={[
          "toggle",
          toggle_color_class(@color),
          toggle_size_class(@size)
        ]}
        {@rest}
      />
      <span :if={@label} class="label">{@label}</span>
    </label>
    """
  end

  defp toggle_color_class(nil), do: nil
  defp toggle_color_class(:primary), do: "toggle-primary"
  defp toggle_color_class(:secondary), do: "toggle-secondary"
  defp toggle_color_class(:accent), do: "toggle-accent"
  defp toggle_color_class(:info), do: "toggle-info"
  defp toggle_color_class(:success), do: "toggle-success"
  defp toggle_color_class(:warning), do: "toggle-warning"
  defp toggle_color_class(:error), do: "toggle-error"

  defp toggle_size_class(:xs), do: "toggle-xs"
  defp toggle_size_class(:sm), do: "toggle-sm"
  defp toggle_size_class(:md), do: nil
  defp toggle_size_class(:lg), do: "toggle-lg"

  # =============================================================================
  # HELPERS
  # =============================================================================

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_max_size(%{max_file_size: size}) when is_integer(size), do: format_bytes(size)
  defp format_max_size(_), do: "10 MB"

  defp image_entry?(%{client_type: type}) when is_binary(type) do
    String.starts_with?(type, "image/")
  end

  defp image_entry?(_), do: false

  defp file_type_icon(filename) do
    ext = filename |> Path.extname() |> String.downcase()

    case ext do
      ".pdf" -> "hero-document"
      ".doc" -> "hero-document-text"
      ".docx" -> "hero-document-text"
      ".xls" -> "hero-table-cells"
      ".xlsx" -> "hero-table-cells"
      ".csv" -> "hero-table-cells"
      ".txt" -> "hero-document-text"
      ".zip" -> "hero-archive-box"
      ".rar" -> "hero-archive-box"
      ".jpg" -> "hero-photo"
      ".jpeg" -> "hero-photo"
      ".png" -> "hero-photo"
      ".gif" -> "hero-photo"
      ".svg" -> "hero-photo"
      _ -> "hero-document"
    end
  end

  defp error_to_string(:too_large), do: gettext("File is too large")
  defp error_to_string(:too_many_files), do: gettext("Too many files selected")
  defp error_to_string(:not_accepted), do: gettext("File type not accepted")
  defp error_to_string(err) when is_binary(err), do: err
  defp error_to_string(_), do: gettext("Upload error")
end
