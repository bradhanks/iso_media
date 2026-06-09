defmodule PerfectPaper.Organizations.Notifier do
  @moduledoc """
  Builds and sends the Organizations context's transactional emails: the team
  invitation. Uses the shared branded `PerfectPaper.Email` layer.
  """
  use Phoenix.Component

  import PerfectPaper.Email.Layout

  alias PerfectPaper.Email

  @doc "Invites someone to join an organization on PerfectPaper."
  @spec deliver_invitation(String.t(), String.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_invitation(invitee_email, organization_name, accept_url) do
    assigns = %{org: organization_name, url: accept_url}

    body = ~H"""
    <.document preview={"You've been invited to join #{@org} on PerfectPaper"}>
      <.eyebrow>Team invitation</.eyebrow>
      <p>You've been invited to join <strong>{@org}</strong> on PerfectPaper.</p>
      <p>
        PerfectPaper is an AI peer reviewer for academic papers. Joining the team gives
        you shared credits and a place to review work together.
      </p>
      <.button href={@url}>Accept invitation</.button>
      <p style="font-size:14px;color:#6b6259;">
        If you weren't expecting this, you can ignore this email.
      </p>
    </.document>
    """

    text = """
    You've been invited to join #{organization_name} on PerfectPaper, an AI peer
    reviewer for academic papers.

    Accept your invitation:
    #{accept_url}

    If you weren't expecting this, you can ignore this email.
    """

    Email.deliver(invitee_email, "You've been invited to join #{organization_name}", body, text)
  end
end
