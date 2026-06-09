defmodule PerfectPaperWeb.PrivacyLive.Rights do
  @moduledoc "Self-service GDPR / CCPA rights request form."
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.Compliance
  alias PerfectPaper.Compliance.DsarRequest

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Your privacy rights"),
       form: to_form(Compliance.new_dsar_request()),
       submitted: false
     )}
  end

  @impl true
  def handle_event("validate", %{"dsar_request" => params}, socket) do
    changeset =
      %DsarRequest{}
      |> DsarRequest.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("submit", %{"dsar_request" => params}, socket) do
    case Compliance.submit_dsar(params) do
      {:ok, _dsar} ->
        {:noreply, assign(socket, submitted: true)}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
