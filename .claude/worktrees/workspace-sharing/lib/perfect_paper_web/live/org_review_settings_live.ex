defmodule PerfectPaperWeb.OrgReviewSettingsLive do
  @moduledoc "Org-admin surface for the organization's review prompt layer."
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Chatbot, Organizations}

  @impl true
  def mount(%{"org_id" => org_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, org} <- Organizations.get_organization(org_id),
         true <- Organizations.admin?(org, user.id) do
      {:ok, assign(socket, org: org, body: Chatbot.get_prompt_layer(:organization, org.id) || "")}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext("You must be an organization admin to edit review settings.")
         )
         |> push_navigate(to: ~p"/new")}
    end
  end

  @impl true
  def handle_event("save", %{"body" => body}, socket) do
    %{org: org} = socket.assigns
    user = socket.assigns.current_scope.user

    case Chatbot.put_prompt_layer(:organization, org.id, body, user.id) do
      {:ok, layer} ->
        {:noreply,
         socket
         |> assign(body: layer.body || "")
         |> put_flash(:info, gettext("Review settings saved."))}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("That prompt is too long (max 4000 characters)."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app
      active={nil}
      title={gettext("Review settings")}
      flash={@flash}
      current_scope={@current_scope}
      credit_alert={@credit_alert}
      low_credit_dismissed?={@low_credit_dismissed?}
      current_workspace={@current_workspace}
      workspaces={@workspaces}
      max_width="max-w-2xl"
    >
      <.header>
        {gettext("Review settings")} — {@org.name}
        <:subtitle>
          {gettext("Custom instructions added to every review for this organization.")}
        </:subtitle>
      </.header>

      <form id="review-settings-form" phx-submit="save" class="mt-6 space-y-3">
        <textarea
          id="review-prompt-body"
          name="body"
          rows="10"
          class="textarea textarea-bordered w-full font-sans"
          placeholder={gettext("e.g. We use APA 7. Emphasize methods and statistical rigor.")}
        >{@body}</textarea>
        <.button variant="primary" phx-disable-with={gettext("Saving…")}>{gettext("Save")}</.button>
      </form>
    </.app>
    """
  end
end
