defmodule PerfectPaper.Credits.Notifier do
  @moduledoc """
  Builds and sends the Credits context's transactional emails: the celebratory
  "you've got a free credit" activation email and the low-balance nudge. Uses
  the shared branded `PerfectPaper.Email` layer.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaper.Email.Layout

  alias PerfectPaper.Email

  @doc "Celebratory email letting a user know a free credit just landed on their account."
  @spec deliver_free_credit_granted(String.t(), pos_integer(), integer(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_free_credit_granted(email, granted, balance, url) do
    assigns = %{granted: granted, balance: balance, url: url}

    body = ~H"""
    <.document preview="A free credit just landed on your account">
      <.eyebrow>On the house</.eyebrow>
      <p>Good news —</p>
      <p>
        We've added <strong>{@granted} free {credit_word(@granted)}</strong> to your
        PerfectPaper account. Consider it a nudge to put another paper in front of your
        AI peer reviewer.
      </p>
      <.panel title="Your balance">{@balance} credits ready to use</.panel>
      <p>
        A single review can sharpen an argument, tighten prose, and catch the small slips before a reader does. The credit's here — the paper's up to you.
      </p>
      <.button href={@url}>Review a paper now</.button>
    </.document>
    """

    text = """
    Good news —

    We've added #{granted} free #{credit_word(granted)} to your PerfectPaper account.
    Your balance is now #{balance} credits.

    Put it to work — review a paper now:
    #{url}
    """

    Email.deliver(email, "You've got a free credit", body, text)
  end

  @doc """
  Nudge sent when a user's credit balance is running low.

  `billing_period` controls the upsell: annual subscribers see an incremental
  credit pack offer; monthly/none subscribers see the 17% annual-plan bundle.
  """
  @spec deliver_low_balance(String.t(), integer(), String.t(), :monthly | :annual) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_low_balance(email, balance, url, billing_period \\ :monthly) do
    assigns = %{balance: balance, url: url, billing_period: billing_period}

    body = ~H"""
    <.document preview="Your PerfectPaper credits are running low">
      <.eyebrow>Running low</.eyebrow>
      <p>Heads up —</p>
      <p>Your PerfectPaper balance is getting low, so reviews may pause soon.</p>
      <.panel title="Your balance">{@balance} credits remaining</.panel>
      <%= if @billing_period == :annual do %>
        <p>
          As an annual member, you can add a credit pack whenever you need extra
          reviews — no plan change required.
        </p>
        <.button href={@url}>Add a credit pack</.button>
      <% else %>
        <p>
          Switch to an annual plan and save 17% — plus get a larger monthly
          allowance so you never run low again.
        </p>
        <.button href={@url}>Switch to annual and save 17%</.button>
      <% end %>
    </.document>
    """

    upsell_text =
      if billing_period == :annual,
        do: "Add a credit pack whenever you need extra reviews — no plan change required.",
        else: "Switch to annual and save 17% — plus get a larger monthly allowance."

    text = """
    Heads up —

    Your PerfectPaper balance is getting low: #{balance} credits remaining.

    #{upsell_text}

    #{url}
    """

    Email.deliver(email, "Your PerfectPaper credits are running low", body, text)
  end

  @doc """
  Localized low-credit upsell email. `attrs` is a map built by
  `Credits.deliver_low_balance_upsell/3`: `to`, `locale`, `balance`, `threshold`,
  `annual?`, `pack_reviews`, `pack_price_cents`, `cta_url`. Copy is rendered in
  the recipient's locale; annual subscribers get a "finish your year" variant.
  """
  @spec deliver_low_balance_upsell(map()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_low_balance_upsell(%{to: to, locale: locale} = a) do
    Gettext.with_locale(PerfectPaperWeb.Gettext, locale, fn ->
      price = PerfectPaper.Billing.Pricing.format_cents(a.pack_price_cents)

      subject =
        if a.annual?,
          do: gettext("Top up to finish your year on PerfectPaper"),
          else: gettext("You're running low on review credits")

      count_line =
        ngettext(
          "You have %{count} review credit left.",
          "You have %{count} review credits left.",
          a.balance,
          count: a.balance
        )

      cta_label = gettext("Get %{n} more reviews for %{price}", n: a.pack_reviews, price: price)

      year_line =
        if a.annual?,
          do: gettext("Top up now to finish your year without interruption."),
          else: gettext("Stock up so your reviews never pause.")

      assigns = %{
        count_line: count_line,
        cta_label: cta_label,
        year_line: year_line,
        url: a.cta_url
      }

      body = ~H"""
      <.document preview="Your PerfectPaper credits are running low">
        <.eyebrow>Running low</.eyebrow>
        <p>{@count_line}</p>
        <p>{@year_line}</p>
        <.button href={@url}>{@cta_label}</.button>
      </.document>
      """

      text = "#{count_line}\n\n#{year_line}\n\n#{cta_label}: #{a.cta_url}\n"

      Email.deliver(to, subject, body, text)
    end)
  end

  defp credit_word(1), do: "credit"
  defp credit_word(_), do: "credits"
end
