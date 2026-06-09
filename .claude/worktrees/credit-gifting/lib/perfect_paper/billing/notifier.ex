defmodule PerfectPaper.Billing.Notifier do
  @moduledoc """
  Builds and sends the Billing context's transactional emails: subscription
  confirmed, payment receipt, payment failed (dunning), and subscription
  canceled. Uses the shared branded `PerfectPaper.Email` layer.
  """
  use Phoenix.Component

  import PerfectPaper.Email.Layout

  alias PerfectPaper.Email

  @doc "Confirms that a subscription to the given plan is now active."
  @spec deliver_subscription_confirmation(String.t(), atom(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_subscription_confirmation(email, plan, url) do
    assigns = %{plan: plan_name(plan), url: url}

    body = ~H"""
    <.document preview="Your PerfectPaper subscription is active">
      <.eyebrow>Subscription confirmed</.eyebrow>
      <p>Thank you for subscribing to PerfectPaper.</p>
      <.panel title="Your plan">{@plan}</.panel>
      <p>Your plan is active and your monthly credits are ready. Here's to sharper papers.</p>
      <.button href={@url}>Go to your workspace</.button>
    </.document>
    """

    text = """
    Thank you for subscribing to PerfectPaper.

    Your plan: #{plan_name(plan)}. It's active now and your monthly credits are ready.

    Go to your workspace:
    #{url}
    """

    Email.deliver(email, "Your PerfectPaper subscription is active", body, text)
  end

  @doc "Sends a receipt for a successful payment."
  @spec deliver_payment_receipt(String.t(), integer(), atom(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_payment_receipt(email, amount_cents, plan, url) do
    assigns = %{amount: format_money(amount_cents), plan: plan_name(plan), url: url}

    body = ~H"""
    <.document preview="Your PerfectPaper receipt">
      <.eyebrow>Receipt</.eyebrow>
      <p>Thanks — your payment went through.</p>
      <.panel title="Amount charged">{@amount} — {@plan}</.panel>
      <p>You can view your full billing history any time from your account.</p>
      <.button href={@url}>View billing history</.button>
    </.document>
    """

    text = """
    Thanks — your PerfectPaper payment went through.

    Amount charged: #{format_money(amount_cents)} (#{plan_name(plan)}).

    View your billing history:
    #{url}
    """

    Email.deliver(email, "Your PerfectPaper receipt", body, text)
  end

  @doc "Dunning email sent when a payment fails."
  @spec deliver_payment_failed(String.t(), atom(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_payment_failed(email, plan, url) do
    assigns = %{plan: plan_name(plan), url: url}

    body = ~H"""
    <.document preview="We couldn't process your PerfectPaper payment">
      <.eyebrow>Payment issue</.eyebrow>
      <p>We weren't able to process your latest payment for your {@plan} plan.</p>
      <p>
        No need to worry — this usually just means a card needs updating. Update your payment method and we'll try again so your reviews keep running.
      </p>
      <.button href={@url}>Update payment method</.button>
    </.document>
    """

    text = """
    We weren't able to process your latest PerfectPaper payment for your
    #{plan_name(plan)} plan.

    This usually just means a card needs updating. Update your payment method
    and we'll try again:
    #{url}
    """

    Email.deliver(email, "Action needed: update your payment method", body, text)
  end

  @doc "Confirms that a subscription has been canceled."
  @spec deliver_subscription_canceled(String.t(), atom(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_subscription_canceled(email, plan, url) do
    assigns = %{plan: plan_name(plan), url: url}

    body = ~H"""
    <.document preview="Your PerfectPaper subscription is canceled">
      <.eyebrow>Subscription canceled</.eyebrow>
      <p>Your {@plan} subscription has been canceled. We're sorry to see you scale back.</p>
      <p>
        Your account stays open and you can pick up right where you left off whenever you're ready.
      </p>
      <.button href={@url}>Reactivate any time</.button>
    </.document>
    """

    text = """
    Your PerfectPaper #{plan_name(plan)} subscription has been canceled.

    Your account stays open — reactivate any time:
    #{url}
    """

    Email.deliver(email, "Your PerfectPaper subscription is canceled", body, text)
  end

  defp plan_name(plan) do
    plan |> to_string() |> String.capitalize() |> Kernel.<>(" plan")
  end

  defp format_money(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end
end
