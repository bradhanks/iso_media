defmodule PerfectPaper.Email do
  @moduledoc """
  Shared rendering and delivery helper for PerfectPaper transactional email.

  This is a shared leaf (like `PerfectPaper.Mailer`), not a context: it performs
  no business logic. Each context's notifier builds its branded HEEx body using
  `PerfectPaper.Email.Layout` and an explicit plaintext fallback, then calls
  `deliver/4`. This module fills in the configured sender identity, stringifies
  the rendered HTML, and hands the message to `PerfectPaper.Mailer` (whose Swoosh
  adapter — Resend in production — is the only place vendor specifics live).

  An explicit plaintext body is required rather than derived from the HTML:
  action URLs live in `href` attributes, so auto-stripping tags would drop them.
  """
  import Swoosh.Email

  alias PerfectPaper.Mailer

  @type body :: Phoenix.LiveView.Rendered.t() | Phoenix.HTML.safe()

  @doc """
  Renders `html_body`, wraps it with the configured sender, and delivers it.

  Returns `{:ok, email}` on success or `{:error, reason}` on transport failure.
  Never raises — callers may log and continue without rolling back state.
  """
  @spec deliver(String.t(), String.t(), body(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver(to, subject, html_body, text_body)
      when is_binary(to) and is_binary(subject) and is_binary(text_body) do
    email =
      new()
      |> to(to)
      |> from(sender())
      |> subject(subject)
      |> html_body(render(html_body))
      |> text_body(text_body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @spec sender() :: {String.t(), String.t()}
  defp sender do
    config = Application.get_env(:perfect_paper, :mail, [])

    {
      Keyword.get(config, :from_name, "PerfectPaper"),
      Keyword.get(config, :from_email, "no-reply@perfectpaper.org")
    }
  end

  @spec render(body()) :: String.t()
  defp render(html_body) do
    html_body
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
