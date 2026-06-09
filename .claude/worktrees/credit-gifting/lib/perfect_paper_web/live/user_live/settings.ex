defmodule PerfectPaperWeb.UserLive.Settings do
  use PerfectPaperWeb, :live_view

  on_mount {PerfectPaperWeb.UserAuth, :require_sudo_mode}

  alias PerfectPaper.Accounts
  alias PerfectPaper.Chatbot

  @impl true
  def render(assigns) do
    ~H"""
    <.app
      active={:account}
      title="Settings"
      flash={@flash}
      current_scope={@current_scope}
      credit_alert={@credit_alert}
      low_credit_dismissed?={@low_credit_dismissed?}
      current_workspace={@current_workspace}
      workspaces={@workspaces}
      max_width="max-w-xl"
    >
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <div class="divider" />

      <.form for={@locale_form} id="locale_form" phx-submit="update_locale">
        <.input
          field={@locale_form[:locale]}
          type="select"
          label="Language"
          options={
            Enum.map(PerfectPaper.Localization.supported_locales(), &{&1.native_name, &1.code})
          }
        />
        <.button variant="primary" phx-disable-with="Saving...">Save Language</.button>
      </.form>

      <div class="divider" />

      <.header>
        Credit alerts
        <:subtitle>Get an email when your balance falls below a threshold.</:subtitle>
      </.header>

      <.form
        for={@credit_alert_form}
        id="credit_alert_form"
        phx-submit="update_credit_alert_threshold"
        phx-change="validate_credit_alert_threshold"
      >
        <.input
          field={@credit_alert_form[:credit_alert_threshold]}
          type="number"
          label="Alert me when my balance drops below"
          min="0"
          placeholder="Leave blank to use the plan default (5 for annual, 2 for monthly)"
        />
        <.button variant="primary" phx-disable-with="Saving...">Save alert</.button>
      </.form>

      <div class="divider" />

      <.header>
        Review preferences
        <:subtitle>Custom instructions added to every review of your papers.</:subtitle>
      </.header>

      <form id="review-preferences-form" phx-submit="save_review_preferences" class="space-y-3">
        <textarea
          id="review-preferences-body"
          name="body"
          rows="8"
          class="textarea textarea-bordered w-full font-sans"
          placeholder="e.g. Prioritize methods and reproducibility; be concise."
        >{@review_body}</textarea>
        <.button variant="primary" phx-disable-with="Saving…">Save preferences</.button>
      </form>
    </.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:locale_form, to_form(Accounts.change_user_locale(user)))
      |> assign(
        :credit_alert_form,
        to_form(Accounts.change_credit_alert_threshold(user), as: "credit_alert")
      )
      |> assign(:review_body, Chatbot.get_prompt_layer(:user, user.id) || "")

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("save_review_preferences", %{"body" => body}, socket) do
    user = socket.assigns.current_scope.user

    case Chatbot.put_prompt_layer(:user, user.id, body, user.id) do
      {:ok, layer} ->
        {:noreply,
         socket
         |> assign(:review_body, layer.body || "")
         |> put_flash(:info, "Review preferences saved.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That prompt is too long (max 4000 characters).")}
    end
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_credit_alert_threshold", %{"credit_alert" => params}, socket) do
    form =
      socket.assigns.current_scope.user
      |> Accounts.change_credit_alert_threshold(params)
      |> Map.put(:action, :validate)
      |> to_form(as: "credit_alert")

    {:noreply, assign(socket, :credit_alert_form, form)}
  end

  def handle_event("update_credit_alert_threshold", %{"credit_alert" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_credit_alert_threshold(user, params) do
      {:ok, _user} ->
        {:noreply, put_flash(socket, :info, "Credit alert updated.")}

      {:error, changeset} ->
        {:noreply,
         assign(
           socket,
           :credit_alert_form,
           to_form(changeset, as: "credit_alert", action: :update)
         )}
    end
  end

  def handle_event("update_locale", %{"user" => %{"locale" => locale}}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_locale(user, locale) do
      {:ok, _user} ->
        # Re-mount via live navigation so :load_locale re-reads the new locale.
        {:noreply,
         socket
         |> put_flash(:info, "Language updated.")
         |> push_navigate(to: ~p"/users/settings")}

      {:error, changeset} ->
        {:noreply, assign(socket, :locale_form, to_form(changeset, action: :update))}
    end
  end
end
