defmodule PerfectPaperWeb.UserLive.Registration do
  @moduledoc """
  Magic-link-first registration. Captures an email, sends a sign-in link, and
  shows an in-place "Check your email" state. Submits are rate limited and
  anti-enumeration: a new, existing, or throttled email all look identical.
  Passwords are set later in Settings (registration is email-only).
  """
  use PerfectPaperWeb, :live_view

  import PerfectPaperWeb.AuthProviders

  alias PerfectPaper.Accounts
  alias PerfectPaper.Accounts.User
  alias PerfectPaperWeb.{ClientMetadata, RateLimit}

  @ip_window_ms 60_000
  @ip_limit 5
  @email_window_ms 60 * 60 * 1000
  @email_limit 5

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-6 py-16 sm:py-24">
        <div :if={@check_email} class="text-center space-y-4">
          <div class="flex justify-center">
            <.icon name="hero-envelope" class="size-12 text-primary" />
          </div>
          <.header>
            {gettext("Check your email")}
            <:subtitle>
              {gettext("If an account exists for %{email}, you'll receive a sign-in link shortly.",
                email: @sent_to
              )}
            </:subtitle>
          </.header>
          <p class="ds-p text-base-content/60">
            {gettext("Didn't get it?")}
            <button type="button" phx-click="resend" class="link link-primary">
              {gettext("Resend")}
            </button>
            {gettext("or")} <.link navigate={~p"/users/log-in"} class="link link-primary">{gettext("log in")}</.link>.
          </p>
        </div>

        <div :if={!@check_email}>
          <div class="text-center">
            <.header>
              {gettext("Create your account")}
              <:subtitle>
                {gettext("Already registered?")}
                <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                  {gettext("Log in")}
                </.link>
                {gettext("to your account now.")}
              </:subtitle>
            </.header>
          </div>

          <.provider_buttons />

          <.form
            for={@form}
            id="registration_form"
            phx-submit="save"
            phx-change="validate"
            class="space-y-4 mt-6"
          >
            <.input
              field={@form[:email]}
              type="email"
              label={gettext("Email")}
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button phx-disable-with={gettext("Sending link...")} class="btn btn-primary w-full">
              {gettext("Send magic link")} <span aria-hidden="true">→</span>
            </.button>
          </.form>

          <p class="ds-p text-center text-xs text-base-content/50 mt-4">
            {gettext("Prefer a password? You can set one in Settings after your first sign-in.")}
          </p>
        </div>
      </div>

      <div
        :if={@modal}
        id="freecredit-nudge"
        class="modal modal-open"
        role="dialog"
        aria-modal="true"
      >
        <div class="modal-box">
          <button
            type="button"
            class="btn btn-sm btn-circle btn-ghost absolute right-3 top-3"
            phx-click="nudge_close"
            aria-label={gettext("Close")}
          >
            ✕
          </button>

          <%= if @modal == :warn do %>
            <h3 class="ds-h3">{gettext("Claim a free review credit")}</h3>
            <p class="ds-p mt-2 text-base-content/70">
              {gettext(
                "PerfectPaper gives writers with an academic or government email (.edu, .gov, or an eligible international equivalent) a free credit to try a review. Want to use one to claim it?"
              )}
            </p>
            <div class="modal-action">
              <button
                type="button"
                id="nudge-no-thanks"
                class="btn btn-ghost"
                phx-click="nudge_no_thanks"
              >
                {gettext("No thanks")}
              </button>
              <button
                type="button"
                id="nudge-get-credit"
                class="btn btn-primary"
                phx-click="nudge_get_credit"
              >
                {gettext("Get my free credit")}
              </button>
            </div>
          <% else %>
            <h3 class="ds-h3">{gettext("Use your academic email")}</h3>
            <p class="ds-p mt-2 text-base-content/70">
              {gettext(
                "Enter a .edu, .gov, or eligible international email to claim your free credit."
              )}
            </p>
            <form id="nudge-email-form" phx-submit="nudge_submit_email" class="mt-4 space-y-3">
              <input
                type="email"
                name="nudge[email]"
                required
                autocomplete="email"
                spellcheck="false"
                class="input input-bordered w-full"
                placeholder={gettext("you@university.edu")}
                aria-label={gettext("Academic email")}
                phx-mounted={JS.focus()}
              />
              <p :if={@modal_error} id="nudge-error" class="text-sm text-error">{@modal_error}</p>
              <div class="modal-action">
                <button type="button" id="nudge-back" class="btn btn-ghost" phx-click="nudge_back">
                  {gettext("Back")}
                </button>
                <button type="submit" id="nudge-ok" class="btn btn-primary">
                  {gettext("OK")}
                </button>
              </div>
            </form>
          <% end %>
        </div>

        <button
          type="button"
          class="modal-backdrop"
          phx-click="nudge_close"
          aria-label={gettext("Close")}
        >
          {gettext("Close")}
        </button>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: PerfectPaperWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign(
       check_email: false,
       sent_to: nil,
       client_ip: ClientMetadata.client_ip(socket),
       referral_code: session["referral_code"],
       # Free-credit nudge modal: nil (hidden) | :warn | :enter_email.
       # `nudge_dismissed?` makes the warning appear at most once.
       modal: nil,
       nudge_dismissed?: false,
       pending_email: nil,
       modal_error: nil
     )
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"user" => %{"email" => email}}, socket) do
    email = String.trim(email)

    # Nudge non-academic sign-ups toward a .edu/.gov email (the free-credit gate)
    # exactly once: the first non-academic submit opens the modal instead of
    # registering. An academic email — or a repeat submit after the modal was
    # dismissed — registers straight away (rate-limit is only spent on a real
    # registration attempt, never on showing the nudge).
    if eligible_or_dismissed?(socket, email) do
      submit_registration(socket, email)
    else
      {:noreply, assign(socket, modal: :warn, pending_email: email, modal_error: nil)}
    end
  end

  # "Get my free credit" → step to the change-email screen.
  def handle_event("nudge_get_credit", _params, socket),
    do: {:noreply, assign(socket, modal: :enter_email, modal_error: nil)}

  # Back from the change-email screen to the warning screen.
  def handle_event("nudge_back", _params, socket),
    do: {:noreply, assign(socket, modal: :warn, modal_error: nil)}

  # Close the modal entirely: it won't reappear, and the next "create account"
  # click registers the original email as-is.
  def handle_event("nudge_close", _params, socket),
    do: {:noreply, assign(socket, modal: nil, nudge_dismissed?: true, modal_error: nil)}

  # "No thanks" → register the originally submitted (non-academic) email as-is.
  def handle_event("nudge_no_thanks", _params, socket),
    do:
      submit_registration(
        assign(socket, modal: nil, nudge_dismissed?: true),
        socket.assigns.pending_email
      )

  # OK on the change-email screen: an academic email registers (and earns the
  # free credit); a non-academic one is a validation error they must Back/close.
  def handle_event("nudge_submit_email", %{"nudge" => %{"email" => new_email}}, socket) do
    new_email = String.trim(new_email)

    if Accounts.academic_email?(new_email) do
      submit_registration(assign(socket, modal: nil), new_email)
    else
      {:noreply,
       assign(
         socket,
         modal_error:
           gettext("Enter a .edu, .gov, or eligible international email to get the free credit.")
       )}
    end
  end

  def handle_event("resend", _params, socket) do
    email = socket.assigns.sent_to

    if email && !rate_limited?(socket, email) do
      _ = deliver_signup_link(%{"email" => email}, socket.assigns[:referral_code])
    end

    {:noreply, put_flash(socket, :info, gettext("If an account exists, we've re-sent the link."))}
  end

  # Register a brand-new email, or — for an address that already exists — send
  # that existing user a link. Either branch ends in the same outward state, so
  # registration cannot be used to probe which emails exist. A new account is
  # linked to its referrer when the visitor arrived via /join?ref=<code>.
  defp deliver_signup_link(%{"email" => email} = params, referral_code) do
    case Accounts.register_user(params) do
      {:ok, user} ->
        _ = maybe_accept_referral(referral_code, user)
        Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

      {:error, _changeset} ->
        case Accounts.get_user_by_email(String.trim(email)) do
          %User{} = user ->
            Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))

          nil ->
            :ok
        end
    end
  end

  defp maybe_accept_referral(nil, _user), do: :ok

  defp maybe_accept_referral(code, user),
    do: PerfectPaper.Referrals.accept_referral(code, user)

  # Skip the nudge when the email already earns the free credit (academic/gov or
  # an active referral), or when the user has already dismissed the modal once.
  defp eligible_or_dismissed?(socket, email) do
    Accounts.academic_email?(email) or socket.assigns.nudge_dismissed? or
      not is_nil(socket.assigns.referral_code)
  end

  # Single terminal path for every register choice: spend the rate-limit budget
  # once, deliver the link (or not), hide the modal, and show the check-email
  # state. Anti-enumeration is preserved — every outcome looks identical.
  defp submit_registration(socket, email) do
    unless rate_limited?(socket, email) do
      _ = deliver_signup_link(%{"email" => email}, socket.assigns[:referral_code])
    end

    {:noreply, socket |> assign(modal: nil) |> to_check_email(email)}
  end

  defp rate_limited?(socket, email) do
    ip = socket.assigns.client_ip || "unknown"
    email_key = String.downcase(email)

    RateLimit.check("auth_submit:ip:#{ip}", @ip_window_ms, @ip_limit) == :rate_limited or
      RateLimit.check("auth_submit:email:#{email_key}", @email_window_ms, @email_limit) ==
        :rate_limited
  end

  defp to_check_email(socket, email) do
    assign(socket, check_email: true, sent_to: email)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
