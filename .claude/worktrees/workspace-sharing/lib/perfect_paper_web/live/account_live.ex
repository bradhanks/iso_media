defmodule PerfectPaperWeb.AccountLive do
  @moduledoc """
  Account settings page for signed-in users. Surfaces profile information,
  subscription status, credit balance, email communication preferences, and
  API key management — all in a single, scrollable settings view.

  The page is read-only except for the email opt-in toggle, which writes to
  the Marketing context. API key management (generation, revocation) is out
  of scope for this pass and will be addressed in a future iteration.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Billing, Credits, Marketing, ApiKeys, Teams}
  alias PerfectPaper.Billing.Subscription

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    socket =
      assign(socket,
        page_title: gettext("Account"),
        user: user,
        subscription: Billing.get_subscription_for_user(user.id),
        balance: Credits.balance(user.id),
        prefs: Marketing.get_preferences(user.id),
        api_keys: ApiKeys.list_keys(user.id),
        teams_link: Teams.get_link_by_user(user.id)
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_opt_in", _params, socket) do
    current = socket.assigns.prefs && socket.assigns.prefs.opt_in

    case Marketing.set_opt_in(socket.assigns.user, !current) do
      {:ok, prefs} ->
        {:noreply,
         socket
         |> assign(:prefs, prefs)
         |> put_flash(
           :info,
           if(!current,
             do: gettext("Email updates enabled."),
             else: gettext("Email updates disabled.")
           )
         )}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not update your preference. Please try again."))}
    end
  end

  def handle_event("teams_unlink", _params, socket) do
    :ok = Teams.unlink(socket.assigns.user.id)

    {:noreply,
     socket
     |> assign(:teams_link, nil)
     |> put_flash(:info, "Microsoft Teams disconnected.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app
      active={:account}
      title={gettext("Account")}
      flash={@flash}
      current_scope={@current_scope}
      credit_alert={@credit_alert}
      low_credit_dismissed?={@low_credit_dismissed?}
      current_workspace={@current_workspace}
      workspaces={@workspaces}
      max_width="max-w-3xl"
    >
      <div class="space-y-6">
        <%!-- ── 1. Profile ── --%>
        <section class="rounded-box border border-base-300 bg-base-100">
          <header class="border-b border-base-300 px-6 py-4">
            <h2 class="ds-h3">{gettext("Profile")}</h2>
            <p class="ds-p mt-0.5 text-base-content/60">
              {gettext("Your identity on PerfectPaper.")}
            </p>
          </header>

          <div class="px-6 py-5">
            <dl class="space-y-4">
              <div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:gap-0">
                <dt class="w-40 shrink-0 font-sans text-sm font-medium text-base-content/60">
                  {gettext("Email address")}
                </dt>
                <dd class="font-sans text-sm text-base-content">
                  {@user.email}
                </dd>
              </div>
            </dl>

            <div class="mt-5 flex items-center gap-3 border-t border-base-300 pt-5">
              <.link
                href={~p"/users/settings"}
                class="btn btn-sm btn-outline font-sans"
              >
                {gettext("Change email or password")}
              </.link>
              <p class="font-sans text-xs text-base-content/50">
                {gettext("Update your login credentials on the settings page.")}
              </p>
            </div>
          </div>
        </section>

        <%!-- ── 2. Subscription ── --%>
        <section class="rounded-box border border-base-300 bg-base-100">
          <header class="border-b border-base-300 px-6 py-4">
            <h2 class="ds-h3">{gettext("Subscription")}</h2>
            <p class="ds-p mt-0.5 text-base-content/60">
              {gettext("Your current billing plan.")}
            </p>
          </header>

          <div class="px-6 py-5">
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div>
                <p class="font-sans text-[11px] font-semibold uppercase tracking-[0.15em] text-base-content/45">
                  {gettext("Current plan")}
                </p>
                <p class="mt-1 font-display text-xl font-semibold">
                  {if @subscription,
                    do: Subscription.plan_label(@subscription),
                    else: gettext("Free preview")}
                </p>
                <p
                  :if={@subscription && @subscription.current_period_end}
                  class="mt-1 font-sans text-xs text-base-content/50"
                >
                  {gettext("Renews %{date}",
                    date: Calendar.strftime(@subscription.current_period_end, "%B %-d, %Y")
                  )}
                </p>
              </div>

              <div class="flex items-center gap-3">
                <.badge
                  :if={@subscription}
                  color={subscription_badge_color(@subscription)}
                  variant="soft"
                >
                  {Subscription.status_label(@subscription)}
                </.badge>
                <.badge :if={!@subscription} color="secondary" variant="soft">
                  {gettext("Free preview")}
                </.badge>
                <.link navigate={~p"/billing"} class="btn btn-primary btn-sm font-sans">
                  {if @subscription && !Subscription.free?(@subscription),
                    do: gettext("Manage plan"),
                    else: gettext("Upgrade")}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <%!-- ── 3. Credits ── --%>
        <section class="rounded-box border border-base-300 bg-base-100">
          <header class="border-b border-base-300 px-6 py-4">
            <h2 class="ds-h3">{gettext("Credits")}</h2>
            <p class="ds-p mt-0.5 text-base-content/60">
              {gettext("Each proofreading review consumes one credit.")}
            </p>
          </header>

          <div class="px-6 py-5">
            <div class="flex items-baseline gap-2">
              <span class="font-display text-4xl font-semibold text-primary">
                {@balance}
              </span>
              <span class="font-sans text-sm text-base-content/60">
                {if @balance == 1, do: gettext("credit remaining"), else: gettext("credits remaining")}
              </span>
            </div>
            <p :if={@balance == 0} class="mt-2 font-serif text-sm text-base-content/65">
              {gettext(
                "You have no credits. Upgrade your plan or purchase additional credits to continue reviewing."
              )}
            </p>
          </div>
        </section>

        <%!-- ── 4. Email preferences ── --%>
        <section class="rounded-box border border-base-300 bg-base-100">
          <header class="border-b border-base-300 px-6 py-4">
            <h2 class="ds-h3">{gettext("Email preferences")}</h2>
            <p class="ds-p mt-0.5 text-base-content/60">
              {gettext("Control which messages PerfectPaper sends to your inbox.")}
            </p>
          </header>

          <div class="px-6 py-5">
            <label class="flex cursor-pointer items-start justify-between gap-4">
              <div>
                <p class="font-sans text-sm font-medium text-base-content">
                  {gettext("Product updates and announcements")}
                </p>
                <p class="mt-0.5 font-serif text-xs text-base-content/60">
                  {gettext(
                    "Occasional emails about new features, improvements, and research tips. We never share your address with third parties."
                  )}
                </p>
              </div>
              <input
                type="checkbox"
                class="toggle toggle-primary mt-0.5 shrink-0"
                checked={@prefs && @prefs.opt_in}
                phx-click="toggle_opt_in"
              />
            </label>
          </div>
        </section>

        <%!-- ── 5. API keys ── --%>
        <section class="rounded-box border border-base-300 bg-base-100">
          <header class="border-b border-base-300 px-6 py-4">
            <h2 class="ds-h3">{gettext("API keys")}</h2>
            <p class="ds-p mt-0.5 text-base-content/60">
              {gettext(
                "Authenticate programmatic access to the PerfectPaper API. Keys are shown only once at creation."
              )}
            </p>
          </header>

          <div class="px-6 py-5">
            <div :if={@api_keys == []} class="font-serif text-sm text-base-content/55">
              {gettext("No API keys yet. Keys you generate will appear here.")}
            </div>

            <ul :if={@api_keys != []} class="divide-y divide-base-300">
              <li
                :for={key <- @api_keys}
                class="flex flex-wrap items-center justify-between gap-3 py-4 first:pt-0 last:pb-0"
              >
                <div class="min-w-0">
                  <p class="font-sans text-sm font-medium text-base-content">
                    {key.name || gettext("Unnamed key")}
                  </p>
                  <p class="mt-0.5 font-sans text-xs text-base-content/50">
                    <span class="font-mono">{key.prefix}••••••••</span>
                    &nbsp;&middot;&nbsp; {gettext("Created %{date}",
                      date: format_date(key.inserted_at)
                    )}
                    <%= if key.last_used_at do %>
                      &nbsp;&middot;&nbsp; {gettext("Last used %{date}",
                        date: format_date(key.last_used_at)
                      )}
                    <% end %>
                  </p>
                </div>

                <.badge color="neutral" variant="soft" size="sm">{gettext("Active")}</.badge>
              </li>
            </ul>

            <p class="mt-5 border-t border-base-300 pt-4 font-serif text-xs text-base-content/50">
              {gettext(
                "Key generation and revocation are available via the API. Full management UI coming soon."
              )}
            </p>
          </div>
        </section>

        <%!-- ── 6. Microsoft Teams ── --%>
        <section class="rounded-box border border-base-300 bg-base-100">
          <div class="p-6">
            <h2 class="ds-h3">Microsoft Teams</h2>

            <p
              :if={@teams_link}
              id="teams-status"
              class="mt-2 font-serif text-sm text-base-content/75"
            >
              Connected. You'll get review notifications in Teams.
            </p>
            <p
              :if={is_nil(@teams_link)}
              id="teams-status"
              class="mt-2 font-serif text-sm text-base-content/55"
            >
              Not connected. Install the PerfectPaper app in Teams to get review notifications.
            </p>

            <div class="mt-4 flex flex-wrap gap-2">
              <a id="teams-download" href={~p"/teams/manifest"} class="btn btn-sm btn-secondary">
                Download Teams app
              </a>
              <button
                :if={@teams_link}
                id="teams-unlink"
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click="teams_unlink"
              >
                Disconnect
              </button>
            </div>
          </div>
        </section>
      </div>
    </.app>
    """
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp subscription_badge_color(%Subscription{status: :active}), do: "success"
  defp subscription_badge_color(%Subscription{status: :past_due}), do: "warning"
  defp subscription_badge_color(%Subscription{status: :canceled}), do: "error"
  # Defensive catch-all: never crash the render on an unexpected/absent status.
  defp subscription_badge_color(_), do: "neutral"

  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d, %Y")
  defp format_date(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%b %-d, %Y")
  defp format_date(nil), do: "—"
end
