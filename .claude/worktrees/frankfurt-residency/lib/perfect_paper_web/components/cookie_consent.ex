defmodule PerfectPaperWeb.CookieConsent do
  @moduledoc """
  Cookie-consent UI: the Google Consent Mode v2 head signals, the consent
  banner, and the reusable preference form (shared by the banner's customize
  panel and the standalone `/cookie-settings` page).

  All three are driven by a `PerfectPaper.Compliance.CookieConsent` struct
  assigned upstream by `PerfectPaperWeb.Plugs.FetchCookieConsent`.
  """

  use PerfectPaperWeb, :html

  alias PerfectPaper.Compliance

  @doc """
  Google Consent Mode v2 signals, emitted in `<head>` before any tag.

  Defaults every advertising/analytics signal to `denied`, then immediately
  updates to the visitor's effective state. When a GTM container is configured it
  is loaded here too — but it stays dormant until consent is granted.
  """
  attr :consent, :map, required: true

  def consent_mode_head(assigns) do
    # HEEx renders the contents of a <script> tag verbatim (no `{...}`
    # interpolation), so the full tag is assembled as a string and injected with
    # `raw/1` from normal markup context. The content is our own static JS.
    assigns =
      assigns
      |> assign(:consent_tag, consent_mode_tag(assigns.consent))
      |> assign(:gtm_tag, gtm_tag(Compliance.gtm_container_id()))

    ~H"""
    {Phoenix.HTML.raw(@consent_tag)}{Phoenix.HTML.raw(@gtm_tag)}
    """
  end

  @doc """
  The consent banner, pinned to the bottom of the viewport until the visitor
  decides. Offers accept-all, reject-non-essential, and a no-JS customize panel.
  """
  attr :consent, :map, required: true
  attr :return_to, :string, default: "/"

  def banner(assigns) do
    ~H"""
    <div
      id="cookie-consent-banner"
      role="dialog"
      aria-modal="false"
      aria-labelledby="cookie-consent-title"
      class="fixed inset-x-0 bottom-0 z-50 motion-safe:animate-[fade-in_200ms_ease-out]"
    >
      <div class="ds-container py-4">
        <div class="rounded-box border border-base-300 bg-base-100 p-5 shadow-lg sm:p-6">
          <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
            <div class="max-w-2xl">
              <h2
                id="cookie-consent-title"
                class="font-display text-lg font-semibold text-base-content"
              >
                {gettext("Your privacy choices")}
              </h2>
              <p class="mt-1.5 font-serif text-sm leading-relaxed text-base-content/75">
                {gettext(
                  "We use essential cookies to keep you signed in and to run PerfectPaper securely. With your permission we also use analytics to understand how the service is used. You can change this any time. Read our"
                )} <.link
                  navigate={~p"/privacy"}
                  class="link link-hover text-primary"
                >{gettext("privacy notice")}</.link>.
              </p>
            </div>

            <.form
              for={%{}}
              as={:consent}
              action={~p"/cookie-consent"}
              method="post"
              class="flex shrink-0 flex-col gap-3 lg:items-end"
            >
              <input type="hidden" name="return_to" value={@return_to} />

              <div class="flex flex-wrap gap-2 lg:justify-end">
                <button
                  type="submit"
                  name="action"
                  value="reject_all"
                  class="btn btn-sm btn-soft rounded-lg font-sans"
                >
                  {gettext("Reject non-essential")}
                </button>
                <button
                  type="submit"
                  name="action"
                  value="accept_all"
                  class="btn btn-sm btn-primary rounded-lg font-sans font-semibold"
                >
                  {gettext("Accept all")}
                </button>
              </div>

              <details class="group w-full lg:w-80">
                <summary class="cursor-pointer list-none font-sans text-xs font-medium text-base-content/60 hover:text-base-content">
                  <span class="underline underline-offset-2">{gettext("Customize choices")}</span>
                </summary>
                <div class="mt-3 rounded-lg border border-base-300 bg-base-200/40 p-4">
                  <.preference_fields consent={@consent} />
                  <button
                    type="submit"
                    name="action"
                    value="save"
                    class="btn btn-sm btn-secondary mt-2 w-full rounded-lg font-sans"
                  >
                    {gettext("Save choices")}
                  </button>
                </div>
              </details>
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The standalone preference form used by the `/cookie-settings` page. Mirrors the
  banner's customize panel but stands on its own so consent is withdrawable any
  time (a GDPR requirement).
  """
  attr :consent, :map, required: true
  attr :return_to, :string, default: "/cookie-settings"

  def preference_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:consent}
      action={~p"/cookie-consent"}
      method="post"
      class="flex flex-col gap-5"
    >
      <input type="hidden" name="return_to" value={@return_to} />
      <.preference_fields consent={@consent} />
      <div class="flex flex-wrap gap-2">
        <button
          type="submit"
          name="action"
          value="reject_all"
          class="btn btn-sm btn-soft rounded-lg font-sans"
        >
          {gettext("Reject non-essential")}
        </button>
        <button
          type="submit"
          name="action"
          value="save"
          class="btn btn-sm btn-primary rounded-lg font-sans font-semibold"
        >
          {gettext("Save preferences")}
        </button>
      </div>
    </.form>
    """
  end

  # Shared category checkboxes. Essential is shown but locked on.
  attr :consent, :map, required: true

  defp preference_fields(assigns) do
    ~H"""
    <fieldset class="flex flex-col gap-3">
      <legend class="sr-only">Cookie categories</legend>

      <.category
        name="essential"
        title={gettext("Strictly necessary")}
        description={
          gettext(
            "Required to sign you in, keep the service secure, and remember these choices. Always on."
          )
        }
        checked={true}
        locked={true}
      />
      <.category
        name="consent[analytics]"
        title={gettext("Analytics")}
        description={gettext("Helps us understand how PerfectPaper is used so we can improve it.")}
        checked={@consent.analytics}
        locked={false}
      />
      <.category
        name="consent[marketing]"
        title={gettext("Marketing")}
        description={gettext("Used to measure and personalize campaigns about PerfectPaper.")}
        checked={@consent.marketing}
        locked={false}
      />
    </fieldset>
    """
  end

  attr :name, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :checked, :boolean, required: true
  attr :locked, :boolean, default: false

  defp category(assigns) do
    ~H"""
    <label class="flex cursor-pointer items-start gap-3">
      <input
        type="checkbox"
        name={@name}
        value="true"
        checked={@checked}
        disabled={@locked}
        class="checkbox checkbox-sm checkbox-primary mt-0.5"
      />
      <span>
        <span class="block font-sans text-sm font-semibold text-base-content">{@title}</span>
        <span class="block font-sans text-xs text-base-content/60">{@description}</span>
      </span>
    </label>
    """
  end

  # --- Consent Mode v2 / GTM script tags (built as strings; see consent_mode_head/1) ---

  defp consent_mode_tag(consent) do
    ~s(<script id="consent-mode">\n#{consent_mode_js(consent)}</script>)
  end

  defp gtm_tag(nil), do: ""

  defp gtm_tag(container_id) do
    ~s(<script id="gtm-loader">\n#{gtm_js(container_id)}</script>)
  end

  defp consent_mode_js(consent) do
    """
    window.dataLayer = window.dataLayer || [];
    function gtag(){dataLayer.push(arguments);}
    gtag('consent', 'default', {
      'ad_storage': 'denied',
      'ad_user_data': 'denied',
      'ad_personalization': 'denied',
      'analytics_storage': 'denied',
      'functionality_storage': 'granted',
      'security_storage': 'granted',
      'wait_for_update': 500
    });
    gtag('consent', 'update', {
      'analytics_storage': '#{granted(consent.analytics)}',
      'ad_storage': '#{granted(consent.marketing)}',
      'ad_user_data': '#{granted(consent.marketing)}',
      'ad_personalization': '#{granted(consent.marketing)}'
    });
    """
  end

  defp gtm_js(container_id) do
    """
    (function(w,d,s,l,i){w[l]=w[l]||[];w[l].push({'gtm.start':
    new Date().getTime(),event:'gtm.js'});var f=d.getElementsByTagName(s)[0],
    j=d.createElement(s),dl=l!='dataLayer'?'&l='+l:'';j.async=true;j.src=
    'https://www.googletagmanager.com/gtm.js?id='+i+dl;f.parentNode.insertBefore(j,f);
    })(window,document,'script','dataLayer','#{container_id}');
    """
  end

  defp granted(true), do: "granted"
  defp granted(_), do: "denied"
end
