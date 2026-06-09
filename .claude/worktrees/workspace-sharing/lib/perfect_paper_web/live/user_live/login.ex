defmodule PerfectPaperWeb.UserLive.Login do
  @moduledoc """
  Magic-link-first login with a "use a password instead" toggle. The magic-link
  path is rate limited and anti-enumeration (existing and unknown emails look
  identical) and shows an in-place "Check your email" state. The password path
  posts to `UserSessionController` unchanged.
  """
  use PerfectPaperWeb, :live_view

  import PerfectPaperWeb.AuthProviders

  alias PerfectPaper.{Accounts, SSO}
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
        </div>

        <div :if={!@check_email} class="space-y-4">
          <div class="text-center">
            <.header>
              <p>{gettext("Log in")}</p>
              <:subtitle>
                <%= if @current_scope do %>
                  {gettext("You need to reauthenticate to perform sensitive actions on your account.")}
                <% else %>
                  {gettext("Don't have an account?")} <.link
                    navigate={~p"/users/register"}
                    class="font-semibold text-brand hover:underline"
                    phx-no-format
                  >{gettext("Sign up")}</.link> {gettext("for an account now.")}
                <% end %>
              </:subtitle>
            </.header>
          </div>

          <div :if={local_mail_adapter?()} class="alert alert-info">
            <.icon name="hero-information-circle" class="size-6 shrink-0" />
            <div>
              <p>{gettext("You are running the local mail adapter.")}</p>
              <p>
                {gettext("To see sent emails, visit")} <.link href="/dev/mailbox" class="underline">{gettext("the mailbox page")}</.link>.
              </p>
            </div>
          </div>

          <.provider_buttons />

          <.form
            :let={f}
            :if={!@password_mode}
            for={@form}
            id="login_form_magic"
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
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

          <.form
            :let={f}
            :if={@password_mode}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label={gettext("Email")}
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label={gettext("Password")}
              autocomplete="current-password"
              spellcheck="false"
            />
            <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
              {gettext("Log in and stay logged in")} <span aria-hidden="true">→</span>
            </.button>
            <.button class="btn btn-primary btn-soft w-full mt-2">
              {gettext("Log in only this time")}
            </.button>
          </.form>

          <div class="text-center">
            <button type="button" phx-click="toggle_password" class="link link-primary text-sm">
              {if @password_mode,
                do: gettext("Use a magic link instead"),
                else: gettext("Use a password instead")}
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       password_mode: false,
       check_email: false,
       sent_to: nil,
       client_ip: ClientMetadata.client_ip(socket)
     )}
  end

  @impl true
  def handle_event("toggle_password", _params, socket) do
    {:noreply, assign(socket, :password_mode, !socket.assigns.password_mode)}
  end

  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    email = String.trim(email)

    # If the email domain has an active SSO config, route to the enterprise IdP
    # instead of the magic-link path. The user is redirected to the SSO start
    # URL; no magic link is sent.
    case SSO.config_for_email(email) do
      %{organization_id: org_id} ->
        {:noreply, push_navigate(socket, to: ~p"/sso/#{org_id}/start")}

      nil ->
        unless rate_limited?(socket, email) do
          if user = Accounts.get_user_by_email(email) do
            Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
          end
        end

        {:noreply, assign(socket, check_email: true, sent_to: email)}
    end
  end

  defp rate_limited?(socket, email) do
    ip = socket.assigns.client_ip || "unknown"
    email_key = String.downcase(email)

    RateLimit.check("auth_submit:ip:#{ip}", @ip_window_ms, @ip_limit) == :rate_limited or
      RateLimit.check("auth_submit:email:#{email_key}", @email_window_ms, @email_limit) ==
        :rate_limited
  end

  defp local_mail_adapter? do
    Application.get_env(:perfect_paper, PerfectPaper.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
