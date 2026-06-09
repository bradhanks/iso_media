defmodule PerfectPaperWeb.LowCreditBanner do
  @moduledoc """
  Stateless low-credit banner: shows whenever the current personal balance is at
  or below the effective threshold (threshold > 0) and the session hasn't
  dismissed it. Derived from balance on each mount — no event needed,
  reconnect-safe. CTA → the 12-pack at the visitor's band price; annual variant.
  """
  use PerfectPaperWeb, :html

  alias PerfectPaper.Billing.{Prices, Pricing}

  attr :alert, :map, required: true, doc: "%{balance, threshold, annual?, band}"
  attr :dismissed?, :boolean, default: false

  @spec banner(map()) :: Phoenix.LiveView.Rendered.t()
  def banner(assigns) do
    show? =
      not assigns.dismissed? and
        assigns.alert.threshold > 0 and
        assigns.alert.balance <= assigns.alert.threshold

    assigns = assign(assigns, show?: show?, price: pack_price_string(assigns.alert.band))

    ~H"""
    <div
      :if={@show?}
      data-testid="low-credit-banner"
      role="status"
      class="alert alert-warning mb-4 flex items-center justify-between gap-3 rounded-box"
    >
      <span class="font-sans text-sm">
        <%= if @alert.annual? do %>
          {ngettext(
            "You have %{count} review credit left this year.",
            "You have %{count} review credits left this year.",
            @alert.balance,
            count: @alert.balance
          )}
        <% else %>
          {ngettext(
            "You have %{count} review credit left.",
            "You have %{count} review credits left.",
            @alert.balance,
            count: @alert.balance
          )}
        <% end %>
      </span>

      <span class="flex items-center gap-2">
        <.link navigate="/billing" class="btn btn-sm btn-primary font-sans">
          {gettext("Get more for %{price}", price: @price)}
        </.link>
        <button
          type="button"
          class="btn btn-ghost btn-sm btn-square motion-safe:transition"
          aria-label={gettext("Dismiss")}
          phx-click={
            JS.hide(to: "[data-testid='low-credit-banner']")
            |> JS.dispatch("phx:dismiss-low-credit")
          }
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </span>
    </div>
    """
  end

  defp pack_price_string(band) do
    pack = Enum.find(Prices.credit_packs(), &(&1.key == :pack_12))
    Pricing.format_cents(Pricing.pack_price_for(pack, band).price)
  end
end
