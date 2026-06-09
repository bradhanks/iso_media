defmodule PerfectPaperWeb.CookieConsentHTML do
  @moduledoc """
  Renders the standalone cookie preferences page served by
  `PerfectPaperWeb.CookieConsentController`.
  """

  use PerfectPaperWeb, :html

  import PerfectPaperWeb.CookieConsent, only: [preference_form: 1]

  attr :consent, :map, required: true
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil

  def show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section class="ds-container pt-14 pb-20 lg:pt-20">
        <div class="max-w-2xl">
          <p class="font-sans mb-4 inline-flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.16em] text-primary">
            <span class="inline-block size-[7px] rounded-full bg-accent"></span> Privacy
          </p>
          <h1 class="font-display mb-4 text-[clamp(2rem,3vw,3rem)] font-semibold leading-[1.08] tracking-[-0.025em]">
            Cookie settings
          </h1>
          <p class="font-serif mb-8 max-w-[34rem] text-[1.075rem] leading-relaxed text-base-content/70">
            Choose which cookies PerfectPaper may use. Strictly necessary cookies keep you signed in
            and the service secure, so they are always on. You can change the rest whenever you like —
            we will remember your choice. See our
            <.link navigate={~p"/privacy"} class="link link-hover text-primary">privacy notice</.link>
            for the full detail.
          </p>

          <div class="rounded-box border border-base-300 bg-base-100 p-6 shadow-sm">
            <.preference_form consent={@consent} return_to={~p"/cookie-settings"} />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
