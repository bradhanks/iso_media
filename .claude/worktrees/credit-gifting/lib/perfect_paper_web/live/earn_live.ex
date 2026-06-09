defmodule PerfectPaperWeb.EarnLive do
  @moduledoc """
  The "Earn credits" page: a signed-in user's referral dashboard.

  Displays the user's referral code (or a prompt to generate one), a warm
  explanation of the referral programme, a "How it works" steps walkthrough,
  and a historical table of all referrals with their current status.

  Mutations are mediated entirely through `PerfectPaper.Referrals`; this view
  holds no business logic of its own.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.Referrals
  alias Phoenix.LiveView.JS

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(page_title: gettext("Earn credits"))
     |> assign(user: user)
     |> assign(referrals: Referrals.status(user.id))}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("generate", _params, socket) do
    user = socket.assigns.user

    case Referrals.register(user) do
      {:ok, _referral} ->
        {:noreply,
         socket
         |> assign(referrals: Referrals.status(user.id))
         |> put_flash(:info, gettext("Your referral link is ready."))}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("We couldn't generate your referral link. Please try again.")
         )}
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.app
      active={:earn}
      title={gettext("Earn credits")}
      flash={@flash}
      current_scope={@current_scope}
      credit_alert={@credit_alert}
      low_credit_dismissed?={@low_credit_dismissed?}
      current_workspace={@current_workspace}
      workspaces={@workspaces}
      max_width="max-w-3xl"
    >
      <div class="space-y-6">
        <%!-- Hero / intro card --%>
        <section class="rounded-box border border-base-300 bg-base-100 p-6">
          <p class="ds-eyebrow mb-2">{gettext("Referral programme")}</p>
          <h1 class="ds-h2 mb-3">{gettext("Earn free review credits")}</h1>
          <p class="ds-lead text-base-content/70">
            {gettext(
              "Invite colleagues to PerfectPaper and both of you receive complimentary review credits when they make their first review. Share your personal referral link with anyone who has not yet created an account."
            )}
          </p>
        </section>

        <%!-- Referral-code card --%>
        <section class="rounded-box border border-base-300 bg-base-100 p-6">
          <h2 class="ds-h3 mb-4">{gettext("Your referral link")}</h2>

          <%= if @referrals != [] do %>
            <%!-- Show the most recent referral code in a copyable input --%>
            <% latest = List.first(@referrals) %>
            <p class="ds-p mb-3 text-base-content/65">
              {gettext(
                "Share this link with colleagues. Credits are issued automatically once they complete their first review."
              )}
            </p>
            <div class="flex items-center gap-2">
              <input
                type="text"
                class="input input-bordered flex-1 font-sans text-sm"
                readonly
                value={"https://perfectpaper.io/join?ref=#{latest.referral_code}"}
                aria-label={gettext("Your referral link")}
              />
              <button
                type="button"
                class="btn btn-outline btn-sm font-sans"
                phx-click={
                  JS.dispatch("phx:copy",
                    detail: %{text: "https://perfectpaper.io/join?ref=#{latest.referral_code}"}
                  )
                }
                aria-label={gettext("Copy referral link")}
                data-testid="copy-referral-link"
              >
                {gettext("Copy")}
              </button>
            </div>
          <% else %>
            <%!-- Prompt to generate --%>
            <p class="ds-p mb-4 text-base-content/65">
              {gettext(
                "You do not have a referral link yet. Generate one to start earning credits for every colleague you bring aboard."
              )}
            </p>
            <button
              type="button"
              class="btn btn-primary font-sans font-semibold"
              phx-click="generate"
            >
              {gettext("Create my referral link")}
            </button>
          <% end %>
        </section>

        <%!-- How it works — daisyUI steps --%>
        <section class="rounded-box border border-base-300 bg-base-100 p-6">
          <h2 class="ds-h3 mb-6">{gettext("How it works")}</h2>

          <ul class="steps steps-horizontal w-full">
            <li class="step step-primary">
              <span class="font-sans text-sm">{gettext("Share your link")}</span>
            </li>
            <li class="step step-primary">
              <span class="font-sans text-sm">{gettext("Colleague signs up")}</span>
            </li>
            <li class="step">
              <span class="font-sans text-sm">{gettext("Both receive credits")}</span>
            </li>
          </ul>

          <div class="mt-6 grid gap-4 sm:grid-cols-3">
            <div class="space-y-1">
              <p class="font-sans text-sm font-semibold text-base-content">
                {gettext("Share your link")}
              </p>
              <p class="font-serif text-sm text-base-content/65">
                {gettext(
                  "Copy your personal referral link and send it to a colleague who has not yet created a PerfectPaper account."
                )}
              </p>
            </div>
            <div class="space-y-1">
              <p class="font-sans text-sm font-semibold text-base-content">
                {gettext("Colleague signs up")}
              </p>
              <p class="font-serif text-sm text-base-content/65">
                {gettext(
                  "Your colleague registers using your link. Their account is automatically associated with your referral."
                )}
              </p>
            </div>
            <div class="space-y-1">
              <p class="font-sans text-sm font-semibold text-base-content">
                {gettext("Both receive credits")}
              </p>
              <p class="font-serif text-sm text-base-content/65">
                {gettext(
                  "Once they complete their first review, you each receive free review credits — no further action needed."
                )}
              </p>
            </div>
          </div>
        </section>

        <%!-- Referral history table --%>
        <section class="rounded-box border border-base-300 bg-base-100 p-6">
          <h2 class="ds-h3 mb-4">{gettext("Referral history")}</h2>

          <%= if @referrals == [] do %>
            <p class="font-serif text-sm text-base-content/55">
              {gettext("No referrals yet. Share your link to get started.")}
            </p>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-sm w-full font-sans">
                <thead>
                  <tr class="border-b border-base-300">
                    <th class="ds-label text-base-content/45">
                      {gettext("Code")}
                    </th>
                    <th class="ds-label text-base-content/45">
                      {gettext("Status")}
                    </th>
                    <th class="ds-label text-base-content/45">
                      {gettext("Created")}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={referral <- @referrals}
                    class="border-b border-base-200 last:border-0"
                  >
                    <td class="font-mono text-xs text-base-content/70">
                      {referral.referral_code}
                    </td>
                    <td>
                      <.badge color={status_badge_color(referral.status)} variant="soft" size="sm">
                        {status_label(referral.status)}
                      </.badge>
                    </td>
                    <td class="text-sm text-base-content/50">
                      {Calendar.strftime(referral.inserted_at, "%d %b %Y")}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      </div>
    </.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec status_badge_color(atom()) :: String.t()
  defp status_badge_color(:pending), do: "neutral"
  defp status_badge_color(:accepted), do: "info"
  defp status_badge_color(:rewarded), do: "success"

  @spec status_label(atom()) :: String.t()
  defp status_label(:pending), do: gettext("Pending")
  defp status_label(:accepted), do: gettext("Accepted")
  defp status_label(:rewarded), do: gettext("Rewarded")
end
