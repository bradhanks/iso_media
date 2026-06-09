defmodule PerfectPaper.Compliance.Notifier do
  @moduledoc "Sends DSAR / privacy-rights notifications to the privacy team."
  use Phoenix.Component

  import PerfectPaper.Email.Layout

  alias PerfectPaper.Compliance.DsarRequest
  alias PerfectPaper.Email

  @privacy_email "privacy@perfectpaper.ink"

  @doc "Notifies the privacy team of an inbound DSAR."
  @spec deliver_dsar_notification(DsarRequest.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_dsar_notification(%DsarRequest{} = dsar) do
    type_label = DsarRequest.request_type_label(dsar.request_type)
    assigns = %{dsar: dsar, type_label: type_label}

    body = ~H"""
    <.document preview="New privacy rights request">
      <.eyebrow>Privacy request</.eyebrow>
      <p>A rights request was submitted via the PerfectPaper self-service form.</p>
      <.panel title="Request type">{@type_label}</.panel>
      <.panel title="Name">{@dsar.name}</.panel>
      <.panel title="Email">{@dsar.email}</.panel>
      <%= if @dsar.message && @dsar.message != "" do %>
        <.panel title="Additional details">{@dsar.message}</.panel>
      <% end %>
      <p style="font-size:13px;color:#6b6259;">
        Respond within 30 days as required by applicable law. Verify the requestor's
        identity before sharing or deleting any data.
      </p>
    </.document>
    """

    text = """
    New privacy rights request

    Request type: #{type_label}
    Name: #{dsar.name}
    Email: #{dsar.email}
    #{if dsar.message && dsar.message != "", do: "\nDetails: #{dsar.message}\n", else: ""}
    Respond within 30 days. Verify identity before acting.
    """

    Email.deliver(
      @privacy_email,
      "Privacy request: #{type_label} from #{dsar.name}",
      body,
      text
    )
  end
end
