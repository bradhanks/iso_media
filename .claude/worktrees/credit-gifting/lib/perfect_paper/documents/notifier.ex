defmodule PerfectPaper.Documents.Notifier do
  @moduledoc """
  Builds and sends the Documents context's transactional emails: the
  "proofreading complete" notification. Uses the shared branded
  `PerfectPaper.Email` layer.
  """
  use Phoenix.Component

  import PerfectPaper.Email.Layout

  alias PerfectPaper.Email

  @doc "Notifies a writer that their document's review is ready to read."
  @spec deliver_proofreading_complete(String.t(), String.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_proofreading_complete(email, filename, review_url) do
    assigns = %{filename: filename, url: review_url}

    body = ~H"""
    <.document preview="Your review is ready to read">
      <.eyebrow>Review ready</.eyebrow>
      <p>Your paper has been reviewed and the feedback is ready.</p>
      <.panel title="Document">{@filename}</.panel>
      <p>Open it to read the comments and act on each one — accept, address, or set it aside.</p>
      <.button href={@url}>Read your review</.button>
    </.document>
    """

    text = """
    Your paper has been reviewed and the feedback is ready.

    Document: #{filename}

    Read your review:
    #{review_url}
    """

    Email.deliver(email, "Your review of #{filename} is ready", body, text)
  end
end
