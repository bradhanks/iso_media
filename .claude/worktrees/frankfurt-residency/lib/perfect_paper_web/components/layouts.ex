defmodule PerfectPaperWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PerfectPaperWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col bg-base-100">
      <.site_header current_scope={@current_scope} />

      <main class="flex-1">
        {render_slot(@inner_block)}
      </main>

      <.site_footer />
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Universal site header: brand wordmark, marketing nav, theme toggle, and
  auth-aware actions. Converted from `docs/design/mockups/index (1).html`.
  """
  attr :current_scope, :map, default: nil

  def site_header(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-base-300 bg-base-100/90 backdrop-blur">
      <div class="ds-container flex h-16 items-center gap-3">
        <.link navigate={~p"/"} class="flex items-center gap-2.5">
          <.brand_mark />
          <span class="font-display text-xl font-semibold tracking-[-0.01em]">
            Perfect<span class="text-primary">Paper</span><span class="text-accent">.</span>
          </span>
        </.link>

        <nav class="ml-10 hidden items-center gap-8 md:flex">
          <a
            href={~p"/#how-it-works"}
            class="font-sans text-sm text-base-content/75 hover:text-base-content"
          >
            {gettext("How it works")}
          </a>
          <a
            href={~p"/#pricing"}
            class="font-sans text-sm text-base-content/75 hover:text-base-content"
          >
            {gettext("Pricing")}
          </a>
          <.link
            navigate={~p"/examples"}
            class="font-sans text-sm text-base-content/75 hover:text-base-content"
          >
            {gettext("Examples")}
          </.link>
          <.link
            navigate={~p"/enterprise"}
            class="font-sans text-sm text-base-content/75 hover:text-base-content"
          >
            {gettext("Enterprise")}
          </.link>
          <a
            href={~p"/#faq"}
            class="font-sans text-sm text-base-content/75 hover:text-base-content"
          >
            {gettext("FAQ")}
          </a>
          <.link
            navigate={~p"/contact"}
            class="font-sans text-sm text-base-content/75 hover:text-base-content"
          >
            {gettext("Contact")}
          </.link>
        </nav>

        <div class="ml-auto flex items-center gap-3">
          <PerfectPaperWeb.LocaleSwitcher.switcher />
          <%= if @current_scope do %>
            <div class="dropdown dropdown-end">
              <button
                tabindex="0"
                class="flex items-center gap-2 rounded-lg px-1.5 py-1 hover:bg-base-200"
                aria-label="User menu"
              >
                <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-primary/10 font-sans text-sm font-semibold uppercase text-primary">
                  {String.first(@current_scope.user.email)}
                </span>
                <span class="hidden font-sans text-sm text-base-content/75 lg:inline">
                  {@current_scope.user.email}
                </span>
              </button>
              <ul
                tabindex="0"
                class="dropdown-content menu z-50 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
              >
                <li>
                  <.link navigate={~p"/account"} class="font-sans text-sm">
                    {gettext("Account")}
                  </.link>
                </li>
                <li>
                  <.link href={~p"/users/settings"} class="font-sans text-sm">
                    {gettext("Settings")}
                  </.link>
                </li>
                <li>
                  <.link
                    href={~p"/users/log-out"}
                    method="delete"
                    class="font-sans text-sm text-error"
                  >
                    {gettext("Log out")}
                  </.link>
                </li>
              </ul>
            </div>
          <% else %>
            <.link
              href={~p"/users/log-in"}
              class="hidden font-sans text-sm text-base-content/75 hover:text-base-content sm:inline"
            >
              {gettext("Log in")}
            </.link>
            <.link
              navigate={~p"/users/register"}
              class="btn btn-primary btn-sm rounded-lg px-5 font-sans font-semibold"
            >
              {gettext("Go to app")}
            </.link>
          <% end %>
        </div>
      </div>
    </header>
    """
  end

  @doc """
  Universal site footer: brand blurb, link columns, and bottom bar. Converted
  from `docs/design/mockups/index (1).html`.
  """
  def site_footer(assigns) do
    ~H"""
    <footer class="border-t border-base-300">
      <div class="ds-container grid grid-cols-2 gap-8 py-14 md:grid-cols-4">
        <div class="col-span-2 md:col-span-1">
          <div class="mb-3 flex items-center gap-2.5">
            <.brand_mark />
            <span class="font-display text-lg font-semibold">
              Perfect<span class="text-primary">Paper</span><span class="text-accent">.</span>
            </span>
          </div>
          <p class="max-w-[210px] font-serif text-sm text-base-content/60">
            {gettext("Made for researchers, by researchers.")}
          </p>
        </div>

        <.footer_column
          title={gettext("Product")}
          links={[
            {gettext("How it works"), ~p"/#how-it-works"},
            {gettext("Pricing & plans"), ~p"/#pricing"},
            {gettext("Example reports"), ~p"/examples"},
            {gettext("FAQ"), ~p"/#faq"}
          ]}
        />
        <.footer_column
          title={gettext("Company")}
          links={[
            {gettext("Enterprise"), ~p"/enterprise"},
            {gettext("Testimonials"), ~p"/testimonials"},
            {gettext("Contact"), ~p"/contact"},
            {gettext("Trust & privacy"), ~p"/#trust"}
          ]}
        />
        <.footer_column
          title={gettext("Legal")}
          links={[
            {gettext("Privacy policy"), ~p"/privacy"},
            {gettext("Terms of service"), ~p"/terms"},
            {gettext("Cookie settings"), ~p"/cookie-settings"},
            {gettext("Security"), ~p"/enterprise/security"}
          ]}
        />
      </div>

      <div class="border-t border-base-300">
        <div class="ds-container flex flex-col items-center justify-between gap-2 py-5 font-sans text-xs text-base-content/50 sm:flex-row">
          <span>{gettext("© 2026 PerfectPaper, Inc.")}</span>
          <span class="flex items-center gap-2">
            <span class="size-1.5 rounded-full bg-success"></span> {gettext("All systems operational")}
          </span>
        </div>
      </div>
    </footer>
    """
  end

  attr :title, :string, required: true
  attr :links, :list, required: true, doc: "list of {label, href} tuples"

  defp footer_column(assigns) do
    ~H"""
    <nav class="flex flex-col gap-2">
      <h6 class="ds-label mb-1 text-base-content/45">
        {@title}
      </h6>
      <a
        :for={{label, href} <- @links}
        href={href}
        class="font-sans text-sm text-base-content/75 hover:text-base-content"
      >
        {label}
      </a>
    </nav>
    """
  end

  @doc "The mulberry tile logo mark with the gold full-stop dot."
  def brand_mark(assigns) do
    ~H"""
    <span class="relative grid size-8 place-items-center rounded-[9px] bg-primary font-display text-lg font-semibold text-primary-content">
      P<span class="absolute right-[7px] bottom-[8px] size-1.5 rounded-full bg-accent"></span>
    </span>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
