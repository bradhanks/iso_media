defmodule PerfectPaperWeb.BillingSuccessLive do
  @moduledoc """
  Post-checkout landing page (Stripe redirects here on success).

  Handles the **webhook-arrival race**: the subscription is created by Stripe and
  confirmed asynchronously via `customer.subscription.*` → our webhook → an
  emitted `subscription.updated` event. If that hasn't landed yet, the page shows
  an "activating…" spinner and flips to success live when the event arrives. If
  the webhook is delayed or lost, a timeout flips to a "payment received,
  finalizing" fallback (with a link to billing, which reads live DB state) rather
  than spinning forever.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Billing, Events}
  alias PerfectPaper.Billing.Subscription

  # How long to wait for the subscription webhook before the fallback state.
  @activation_timeout_ms 12_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    subscription = Billing.get_subscription_for_user(user.id)
    status = if active?(subscription), do: :success, else: :pending

    if connected?(socket) do
      Events.subscribe(:"subscription.updated")

      if status == :pending,
        do: Process.send_after(self(), :activation_timeout, timeout_ms())
    end

    {:ok,
     socket
     |> assign(
       page_title: gettext("Welcome"),
       user: user,
       plan: subscription && subscription.plan
     )
     |> assign_display(status)}
  end

  @impl true
  # The subscription webhook landed for this user → flip to success.
  def handle_info(
        {:event, %Events.Event{type: :"subscription.updated", actor_id: actor_id, data: data}},
        socket
      ) do
    if actor_id == socket.assigns.user.id do
      plan = Map.get(data, :plan) || socket.assigns.plan
      {:noreply, socket |> assign(plan: plan) |> assign_display(:success)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:activation_timeout, socket) do
    # If the confirmation arrived, leave success untouched; otherwise stop spinning.
    if socket.assigns.status == :success do
      {:noreply, socket}
    else
      {:noreply, assign_display(socket, :timed_out)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp active?(%Subscription{} = sub), do: Subscription.active?(sub)
  defp active?(_), do: false

  defp timeout_ms,
    do:
      Application.get_env(:perfect_paper, :checkout_activation_timeout_ms, @activation_timeout_ms)

  # Precompute the title/subtitle/flags so the template carries no case/cond.
  defp assign_display(socket, :success) do
    assign(socket,
      status: :success,
      title: success_title(socket.assigns.plan),
      subtitle: gettext("Your plan is active. Your review credits are ready to use."),
      show_success?: true,
      show_timed_out?: false,
      show_spinner?: false
    )
  end

  defp assign_display(socket, :timed_out) do
    assign(socket,
      status: :timed_out,
      title: gettext("Payment received"),
      subtitle:
        gettext(
          "Your plan is being finalized — this can take a moment. You can view your billing details now."
        ),
      show_success?: false,
      show_timed_out?: true,
      show_spinner?: false
    )
  end

  defp assign_display(socket, _pending) do
    assign(socket,
      status: :pending,
      title: gettext("Activating your plan…"),
      subtitle: gettext("This takes a few seconds. This page updates automatically."),
      show_success?: false,
      show_timed_out?: false,
      show_spinner?: true
    )
  end

  defp success_title(:starter), do: gettext("You're on Starter")
  defp success_title(:professional), do: gettext("You're on Professional")
  defp success_title(:advanced), do: gettext("You're on Advanced")
  defp success_title(_), do: gettext("You're subscribed")

  @impl true
  def render(assigns) do
    ~H"""
    <.app
      active={:billing}
      title={gettext("Welcome")}
      flash={@flash}
      current_scope={@current_scope}
      credit_alert={@credit_alert}
      low_credit_dismissed?={@low_credit_dismissed?}
      current_workspace={@current_workspace}
      workspaces={@workspaces}
      max_width="max-w-xl"
    >
      <div class="py-20 text-center" data-test-id={"checkout-#{@status}"}>
        <div :if={@show_success?} class="mb-6 inline-block rounded-full bg-primary/10 p-4">
          <.icon name="hero-check-badge" class="size-12 text-primary" />
        </div>
        <div :if={@show_timed_out?} class="mb-6 inline-block rounded-full bg-base-200 p-4">
          <.icon name="hero-check-circle" class="size-12 text-base-content/60" />
        </div>
        <div :if={@show_spinner?} class="loading loading-spinner loading-lg mb-6 text-primary"></div>

        <h1 class={["ds-h2 mb-2", @show_success? && "text-primary"]}>{@title}</h1>
        <p class="ds-lead mx-auto max-w-md text-base-content/65">{@subtitle}</p>

        <div :if={@show_success?} class="mt-8 flex justify-center gap-3">
          <.link navigate={~p"/account"} class="btn btn-primary font-sans font-semibold">
            {gettext("Start a review")}
          </.link>
          <.link navigate={~p"/billing"} class="btn btn-ghost font-sans">
            {gettext("View billing")}
          </.link>
        </div>

        <.link
          :if={@show_timed_out?}
          navigate={~p"/billing"}
          class="btn btn-primary mt-8 font-sans font-semibold"
        >
          {gettext("View billing")}
        </.link>
      </div>
    </.app>
    """
  end
end
