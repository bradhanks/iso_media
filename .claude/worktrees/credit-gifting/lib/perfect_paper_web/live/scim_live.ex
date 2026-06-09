defmodule PerfectPaperWeb.ScimLive do
  @moduledoc "Org-admin SCIM provisioning management: show-once token, base URL, rotate/revoke."
  use PerfectPaperWeb, :live_view
  alias PerfectPaper.{Scim, Organizations}

  @impl true
  def mount(%{"org_id" => org_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, org} <- Organizations.get_organization(org_id),
         true <- Organizations.admin?(org, user.id) do
      {:ok, assign(socket, org: org, token_row: Scim.get_token_by_org(org.id), plaintext: nil)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You must be an organization admin to manage SCIM."))
         |> push_navigate(to: ~p"/new")}
    end
  end

  @impl true
  def handle_event("generate", _params, socket) do
    {:ok, plaintext} =
      Scim.generate_scim_token(socket.assigns.org, socket.assigns.current_scope.user)

    {:noreply,
     assign(socket, plaintext: plaintext, token_row: Scim.get_token_by_org(socket.assigns.org.id))}
  end

  def handle_event("revoke", _params, socket) do
    :ok = Scim.revoke_scim_token(socket.assigns.org)
    {:noreply, assign(socket, token_row: nil, plaintext: nil)}
  end

  # Absolute base URL the admin pastes into Entra. Built from the endpoint (no
  # `url/1` verified-route helper is used elsewhere in this app), so SCIM gets a
  # full scheme+host URL rather than a relative path.
  @spec scim_base_url() :: String.t()
  def scim_base_url, do: PerfectPaperWeb.Endpoint.url() <> "/scim/v2"
end
