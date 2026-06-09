defmodule PerfectPaperWeb.AppShell do
  @moduledoc """
  Brand ("Paper") application-shell components — the signed-in chrome converted
  from `docs/design/mockups/app.html` and modelled on a daisyUI `drawer`.

  The single entry point is `app/1`: a `drawer lg:drawer-open` layout that wraps
  every signed-in page in one consistent shell — a collapsible left navigation
  sidebar (full width → icon rail on desktop, off-canvas on mobile), a top
  header bar, a user-avatar footer menu, and a mobile dock. The two/three-pane
  reading `workspace/1` and its small pane headers + `chat_panel/1` live here too
  so the workspace page composes from the same parts.

  Like `PerfectPaperWeb.DesignSystem`, these are thin, themeable function
  components built only on daisyUI semantic classes + Tailwind utilities, so
  colors resolve from the active `data-theme` (default `paper`). Names here
  intentionally avoid clashing with `PerfectPaperWeb.CoreComponents`.

  Reading vs. operating: long-form text uses the serif faces (`font-serif` /
  `font-display`); controls and labels use `font-sans` (Outfit).

  Desktop collapse is owned by the `SidebarDrawer` JS hook: the header toggle
  (`#app-collapse-toggle`) flips a `data-collapsed` attribute on `#app-shell`,
  and the hook persists it and re-applies it on every LiveView patch/navigation
  — so clicking a nav item never re-expands the rail; only the toggle changes
  the width. `group-data-[collapsed=true]/shell` Tailwind variants shrink the
  rail and hide the wordmark and labels, while the section titles stay
  *invisible but space-occupying* so the icons keep their vertical rhythm (icons
  stay, with native `title` tooltips). The toggle's divider sits at 50% when
  open and 25% when collapsed. The `#app-drawer-toggle` checkbox still drives the
  mobile drawer, which the hook closes by default on mobile.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  @doc """
  The signed-in application shell. Wrap a page's content in it:

      <.app active={:new} title="New review" flash={@flash} current_scope={@current_scope}>
        …page content…
      </.app>

  Pass `:active` as one of `:new | :history | :account | :billing | :earn` to
  highlight the current nav item. Set `scroll={false}` for full-height pages
  (the reading workspace) that manage their own internal scrolling; otherwise
  the content is centered in a scrolling `<main>` capped at `max_width`.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil, doc: "the current scope (for the user menu)"
  attr :active, :atom, default: nil, doc: ":new | :history | :account | :billing | :earn"
  attr :title, :string, default: nil, doc: "centered header title"
  attr :scroll, :boolean, default: true, doc: "false → full-height, no padding (workspace)"
  attr :max_width, :string, default: "max-w-5xl", doc: "content max width when scrolling"

  attr :current_workspace, :map,
    default: nil,
    doc: "the active workspace (renders the switcher; nil → brand wordmark)"

  attr :workspaces, :list, default: [], doc: "the user's workspaces (for the switcher dropdown)"

  attr :credit_alert, :map,
    default: nil,
    doc: "low-credit banner inputs %{balance, threshold, annual?, band}; nil → no banner"

  attr :low_credit_dismissed?, :boolean,
    default: false,
    doc: "true when the visitor dismissed the low-credit banner this session"

  slot :inner_block, required: true
  slot :actions, doc: "right-aligned header actions"

  slot :title_block,
    doc: "custom centered header content (e.g. an editable title); overrides the plain `title`"

  def app(assigns) do
    ws_id = assigns.current_workspace && assigns.current_workspace.id
    assigns = assign(assigns, :nav, nav_items(active: assigns.active, workspace_id: ws_id))

    ~H"""
    <div id="app-shell" class="group/shell drawer lg:drawer-open h-screen" phx-hook="SidebarDrawer">
      <input
        id="app-drawer-toggle"
        type="checkbox"
        class="drawer-toggle"
        checked
        phx-update="ignore"
        aria-label={gettext("Toggle sidebar")}
      />

      <%!-- ── Content column: header + main ─────────────────────────────── --%>
      <div class="drawer-content flex min-h-0 min-w-0 flex-col bg-base-100">
        <header class="flex h-13 shrink-0 items-center gap-2.5 border-b border-base-300 bg-base-100 px-4">
          <button
            type="button"
            id="app-collapse-toggle"
            aria-label={gettext("Collapse or expand sidebar")}
            class="btn btn-ghost btn-sm btn-square -ml-1"
          >
            <svg
              class="size-5"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <rect x="3" y="4" width="18" height="16" rx="2" />
              <%!-- divider: 50% (x=12) when open, 25% (x=7.5) when collapsed --%>
              <path class="group-data-[collapsed=true]/shell:hidden" d="M12 4v16" />
              <path class="hidden group-data-[collapsed=true]/shell:block" d="M7.5 4v16" />
            </svg>
          </button>

          <div class="min-w-0 flex-1">
            <div
              :if={@title_block == []}
              class="truncate text-center font-display text-sm font-semibold"
            >
              {@title}
            </div>
            {render_slot(@title_block)}
          </div>

          <div class="flex items-center gap-1.5">
            {render_slot(@actions)}
            <PerfectPaperWeb.LocaleSwitcher.switcher />
          </div>
        </header>

        <main class={[
          "min-h-0 flex-1",
          @scroll && "overflow-y-auto",
          !@scroll && "flex flex-col overflow-hidden"
        ]}>
          <PerfectPaperWeb.Layouts.flash_group flash={@flash} />
          <div :if={@credit_alert} class={["mx-auto w-full px-5 pt-5 lg:px-8", @max_width]}>
            <PerfectPaperWeb.LowCreditBanner.banner
              alert={@credit_alert}
              dismissed?={@low_credit_dismissed?}
            />
          </div>
          <%= if @scroll do %>
            <div class={["mx-auto w-full px-5 py-7 lg:px-8 pb-24 lg:pb-8", @max_width]}>
              {render_slot(@inner_block)}
            </div>
          <% else %>
            {render_slot(@inner_block)}
          <% end %>
        </main>
      </div>

      <%!-- ── Sidebar (hidden in immersive / full-screen reading mode) ────── --%>
      <div class="drawer-side z-40 group-data-[collapsed=true]/shell:overflow-visible group-data-[immersive=true]/shell:hidden">
        <label for="app-drawer-toggle" aria-label={gettext("Close sidebar")} class="drawer-overlay">
        </label>

        <aside class="flex h-screen w-64 flex-col overflow-hidden border-r border-base-300 bg-base-100 transition-[width] duration-200 group-data-[collapsed=true]/shell:w-[4.5rem]">
          <%!-- workspace switcher (falls back to the brand wordmark) --%>
          <div class="flex h-13 shrink-0 items-center border-b border-base-300 px-2">
            <.live_component
              :if={@current_workspace}
              module={PerfectPaperWeb.WorkspaceSwitcher}
              id="ws-switcher"
              current_user={@current_scope && @current_scope.user}
              current_workspace={@current_workspace}
              workspaces={@workspaces}
            />
            <div :if={is_nil(@current_workspace)} class="flex items-center gap-2.5 px-1.5">
              <img src="/images/icon-mulberry.svg" alt="" class="size-7 shrink-0" />
              <span class="group-data-[collapsed=true]/shell:hidden font-display text-lg font-semibold tracking-tight">
                Perfect<span class="text-primary">Paper</span><span class="text-accent">.</span>
              </span>
            </div>
          </div>

          <%!-- nav --%>
          <nav class="min-h-0 flex-1 overflow-y-auto py-2">
            <ul class="menu menu-sm w-full flex-nowrap gap-0.5 px-2">
              <%= for item <- @nav do %>
                <li
                  :if={item[:section]}
                  class="menu-title group-data-[collapsed=true]/shell:invisible px-2.5 pb-1 pt-3 ds-label text-base-content/40"
                >
                  {item.section}
                </li>
                <li>
                  <.link
                    navigate={item.href}
                    title={item.label}
                    class={[
                      "flex items-center gap-2.5 rounded-lg px-2.5 py-2 font-sans text-sm group-data-[collapsed=true]/shell:justify-center",
                      item[:active] && "menu-active bg-primary/10 font-semibold text-primary",
                      !item[:active] && "text-base-content/80"
                    ]}
                  >
                    <span class="shrink-0 [&_svg]:size-[18px]">
                      {Phoenix.HTML.raw(item.icon)}
                    </span>
                    <span class="group-data-[collapsed=true]/shell:hidden truncate">
                      {item.label}
                    </span>
                  </.link>
                </li>
              <% end %>
            </ul>
          </nav>

          <%!-- user menu --%>
          <div :if={@current_scope} class="shrink-0 border-t border-base-300 p-2">
            <div class="dropdown dropdown-top dropdown-end w-full">
              <button
                tabindex="0"
                class="flex w-full items-center gap-2.5 rounded-lg p-1.5 hover:bg-base-200 group-data-[collapsed=true]/shell:justify-center"
                title={@current_scope.user.email}
                aria-label={gettext("User menu")}
              >
                <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-primary/10 font-sans text-sm font-semibold uppercase text-primary">
                  {String.first(@current_scope.user.email)}
                </span>
                <span class="group-data-[collapsed=true]/shell:hidden min-w-0 flex-1 truncate text-left font-sans text-sm">
                  {@current_scope.user.email}
                </span>
              </button>
              <ul
                tabindex="0"
                class="dropdown-content menu z-50 mb-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
              >
                <li>
                  <.link navigate="/account" class="font-sans text-sm">{gettext("Account")}</.link>
                </li>
                <li>
                  <.link navigate="/users/settings" class="font-sans text-sm">
                    {gettext("Settings")}
                  </.link>
                </li>
                <li>
                  <.link
                    href="/users/log-out"
                    method="delete"
                    class="font-sans text-sm text-error"
                  >
                    {gettext("Log out")}
                  </.link>
                </li>
              </ul>
            </div>
          </div>
        </aside>
      </div>

      <%!-- ── Mobile dock ───────────────────────────────────────────────── --%>
      <nav
        class="dock lg:hidden group-data-[immersive=true]/shell:hidden"
        aria-label={gettext("Primary")}
      >
        <.dock_link
          href={ws_path(@current_workspace, "new")}
          label={gettext("New")}
          active={@active == :new}
        >
          <path d="M12 5v14M5 12h14" />
        </.dock_link>
        <.dock_link
          href={ws_path(@current_workspace, "reviews")}
          label={gettext("Reviews")}
          active={@active == :history}
        >
          <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
        </.dock_link>
        <.dock_link href="/billing" label={gettext("Plans")} active={@active == :billing}>
          <circle cx="9" cy="20" r="1.4" /><circle cx="18" cy="20" r="1.4" />
          <path d="M2 3h3l2.4 12.4a1.5 1.5 0 001.5 1.2h8.7a1.5 1.5 0 001.5-1.2L21 7H6" />
        </.dock_link>
        <.dock_link href="/account" label={gettext("Account")} active={@active == :account}>
          <circle cx="12" cy="8" r="4" /><path d="M5 21a7 7 0 0114 0" />
        </.dock_link>
      </nav>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true, doc: "the icon's inner SVG paths"

  defp dock_link(assigns) do
    ~H"""
    <.link navigate={@href} class={@active && "dock-active"}>
      <svg
        class="size-5"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.7"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        {render_slot(@inner_block)}
      </svg>
      <span class="dock-label">{@label}</span>
    </.link>
    """
  end

  @doc """
  The canonical application navigation shared by every signed-in page so the
  sidebar is identical across the app. Pass `:active` to highlight the current
  item. Each item carries an inline-SVG `:icon` so the collapsed rail is legible.
  """
  @spec nav_items(keyword()) :: [map()]
  def nav_items(opts \\ []) do
    active = Keyword.get(opts, :active)
    ws_id = Keyword.get(opts, :workspace_id)

    [
      %{
        section: gettext("Reviews"),
        label: gettext("New review"),
        href: workspace_path(ws_id, "new"),
        active: active == :new,
        icon:
          ~s(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>)
      },
      %{
        label: gettext("Reviews"),
        href: workspace_path(ws_id, "reviews"),
        active: active == :history,
        icon:
          ~s(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>)
      },
      %{
        section: gettext("Account"),
        label: gettext("Account"),
        href: "/account",
        active: active == :account,
        icon:
          ~s(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="4"/><path d="M5 21a7 7 0 0114 0"/></svg>)
      },
      %{
        label: gettext("Subscription"),
        href: "/billing",
        active: active == :billing,
        icon:
          ~s(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 10h18"/></svg>)
      },
      %{
        label: gettext("Earn credits"),
        href: "/earn",
        active: active == :earn,
        icon:
          ~s(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="8" width="18" height="13" rx="1.5"/><path d="M12 8v13M3 12h18M12 8s-1-5-4-5-3 3 0 5M12 8s1-5 4-5 3 3 0 5"/></svg>)
      }
    ]
  end

  # Workspace-scoped path when a workspace is active, else the bare route (which
  # the redirect controller bounces into the user's workspace).
  defp workspace_path(nil, suffix), do: "/#{suffix}"
  defp workspace_path(id, suffix), do: "/w/#{id}/#{suffix}"

  defp ws_path(nil, suffix), do: "/#{suffix}"
  defp ws_path(%{id: id}, suffix), do: workspace_path(id, suffix)

  @doc """
  The workspace: a flex container holding the `document` and `feedback` panes
  side by side, plus an optional `chat` drawer on the right.

  ## Examples

      <.workspace>
        <:document>…the manuscript…</:document>
        <:feedback>…feedback cards…</:feedback>
        <:chat><.chat_panel>…</.chat_panel></:chat>
      </.workspace>
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :document, required: true, doc: "the left reading pane"
  slot :feedback, required: true, doc: "the middle/right feedback pane"
  slot :chat, doc: "optional right chat drawer"

  def workspace(assigns) do
    ~H"""
    <div
      id="workspace-panes"
      phx-hook="PaneResize"
      class={["flex min-h-0 flex-1 overflow-hidden", @class]}
      {@rest}
    >
      <section
        class="hidden min-w-0 flex-col overflow-hidden border-r border-base-300 lg:flex"
        style="flex: 0 0 var(--doc-basis, 50%)"
      >
        {render_slot(@document)}
      </section>
      <div
        data-resize-handle
        role="separator"
        aria-orientation="vertical"
        aria-label={gettext("Resize the document and feedback panes")}
        tabindex="0"
        class="hidden w-1.5 shrink-0 cursor-col-resize bg-base-300/60 transition-colors hover:bg-primary/40 focus:bg-primary/60 focus:outline-none lg:block"
      >
      </div>
      <section class="flex min-w-0 flex-1 flex-col overflow-hidden bg-base-200/35">
        {render_slot(@feedback)}
      </section>
      <section
        :if={@chat != []}
        class="flex w-90 shrink-0 flex-col overflow-hidden border-l border-base-300 bg-base-100"
      >
        {render_slot(@chat)}
      </section>
    </div>
    """
  end

  @doc """
  The small "DOCUMENT" pane header — an uppercase eyebrow label with an optional
  trailing actions slot.
  """
  attr :label, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :actions, doc: "right-aligned actions"

  def doc_pane_header(assigns) do
    assigns = Map.update!(assigns, :label, fn v -> v || gettext("DOCUMENT") end)

    ~H"""
    <.pane_header label={@label} class={@class} {@rest}>
      <:actions>{render_slot(@actions)}</:actions>
    </.pane_header>
    """
  end

  @doc """
  The small "FEEDBACK" pane header — an uppercase eyebrow label with an optional
  trailing actions slot.
  """
  attr :label, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :actions, doc: "right-aligned actions"

  def feedback_pane_header(assigns) do
    assigns = Map.update!(assigns, :label, fn v -> v || gettext("FEEDBACK") end)

    ~H"""
    <.pane_header label={@label} class={@class} {@rest}>
      <:actions>{render_slot(@actions)}</:actions>
    </.pane_header>
    """
  end

  # Shared implementation behind doc_pane_header/1 and feedback_pane_header/1.
  attr :label, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global
  slot :actions

  defp pane_header(assigns) do
    ~H"""
    <header
      class={[
        "flex h-11 shrink-0 items-center justify-between border-b border-base-300 px-4",
        @class
      ]}
      {@rest}
    >
      <span class="ds-label text-base-content/45">
        {@label}
      </span>
      <div :if={@actions != []} class="flex items-center gap-1.5">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  The right-hand chat drawer: a header, a scrollable `messages` slot, and an
  input row.

  By default the input is a static scaffold. Pass `on_submit` (and optionally
  `on_change` + `draft`) to make it a live form that emits that event with the
  typed text under `input_name`; pass `on_close` to wire the header's ✕ button.
  """
  attr :title, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :class, :string, default: nil
  attr :on_close, :string, default: nil, doc: "phx-click event for the header close button"
  attr :on_submit, :string, default: nil, doc: "phx-submit event; makes the input live"
  attr :on_change, :string, default: nil, doc: "phx-change event for the input"
  attr :draft, :string, default: "", doc: "current input text (so it can be cleared)"
  attr :input_name, :string, default: "message"
  attr :rest, :global
  slot :messages, doc: "the conversation transcript"

  def chat_panel(assigns) do
    assigns =
      assigns
      |> Map.update!(:title, fn v -> v || gettext("Chat") end)
      |> Map.update!(:placeholder, fn v -> v || gettext("Ask a question about this review…") end)

    ~H"""
    <div class={["flex min-h-0 flex-1 flex-col", @class]} {@rest}>
      <header class="flex h-11 shrink-0 items-center justify-between border-b border-base-300 px-4">
        <span class="font-display text-sm font-semibold">{@title}</span>
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-square"
          aria-label={gettext("Close chat")}
          phx-click={@on_close}
        >
          <svg
            class="size-4"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
          >
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
        </button>
      </header>

      <div class="flex flex-1 flex-col gap-3 overflow-y-auto px-4 py-4">
        {render_slot(@messages)}
      </div>

      <div class="shrink-0 border-t border-base-300 p-3">
        <form
          :if={@on_submit}
          phx-submit={@on_submit}
          phx-change={@on_change}
          class="flex items-end gap-2"
        >
          <input
            type="text"
            name={@input_name}
            value={@draft}
            autocomplete="off"
            placeholder={@placeholder}
            class="input input-bordered min-h-10 flex-1 font-sans text-sm"
          />
          <button type="submit" class="btn btn-primary btn-sm btn-square" aria-label={gettext("Send")}>
            <svg
              class="size-4"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M22 2L11 13M22 2l-7 20-4-9-9-4 20-7z" />
            </svg>
          </button>
        </form>

        <div :if={!@on_submit} class="flex items-end gap-2">
          <textarea
            rows="1"
            placeholder={@placeholder}
            class="textarea textarea-bordered min-h-10 flex-1 resize-none font-sans text-sm"
          ></textarea>
          <button type="button" class="btn btn-primary btn-sm btn-square" aria-label={gettext("Send")}>
            <svg
              class="size-4"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M22 2L11 13M22 2l-7 20-4-9-9-4 20-7z" />
            </svg>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
