defmodule PerfectPaperWeb.AuthProviders do
  @moduledoc """
  Renders a row of social sign-in buttons for the currently configured
  providers, with an "or" divider. Renders nothing when none are configured.
  Each button is a full-page link to the OAuth controller (not a LiveView event).
  """
  use PerfectPaperWeb, :html

  alias PerfectPaper.Accounts

  @labels %{
    "google" => "Google",
    "github" => "GitHub",
    "microsoft" => "Microsoft",
    "orcid" => "ORCID",
    "apple" => "Apple"
  }

  @doc "Social sign-in row. Pass no assigns."
  attr :rest, :global

  def provider_buttons(assigns) do
    assigns = assign(assigns, :providers, Accounts.configured_providers())

    ~H"""
    <div :if={@providers != []} class="space-y-4" {@rest}>
      <div class="grid grid-cols-3 gap-2">
        <.link
          :for={provider <- @providers}
          href={~p"/auth/#{provider}"}
          class="btn btn-outline flex items-center justify-center gap-2"
          aria-label={"Continue with #{label(provider)}"}
        >
          <.provider_icon provider={provider} />
          <span class="sr-only">{label(provider)}</span>
        </.link>
      </div>
      <div class="divider text-xs text-base-content/50">or</div>
    </div>
    """
  end

  defp label(provider), do: Map.get(@labels, provider, provider)

  # Minimal monochrome brand marks (currentColor). Swap for full-colour later.
  attr :provider, :string, required: true

  defp provider_icon(%{provider: "google"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class="size-5" fill="currentColor" aria-hidden="true">
      <path d="M12 11v2.8h4a3.4 3.4 0 0 1-1.5 2.2v1.8h2.4A7.3 7.3 0 0 0 19.6 12c0-.5 0-1-.1-1.4H12z" />
      <path d="M12 20a7.6 7.6 0 0 0 5.3-1.9l-2.4-1.8a4.6 4.6 0 0 1-7-2.4H5.4v1.9A8 8 0 0 0 12 20z" />
      <path d="M9.9 13.9a4.7 4.7 0 0 1 0-3l-2.5-1.9a8 8 0 0 0 0 6.8l2.5-1.9z" />
      <path d="M12 7.6a4.3 4.3 0 0 1 3 1.2l2.2-2.2A7.7 7.7 0 0 0 12 4a8 8 0 0 0-6.6 3.9l2.5 1.9A4.6 4.6 0 0 1 12 7.6z" />
    </svg>
    """
  end

  defp provider_icon(%{provider: "github"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class="size-5" fill="currentColor" aria-hidden="true">
      <path d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48l-.01-1.7c-2.78.6-3.37-1.34-3.37-1.34-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.6.07-.6 1 .07 1.53 1.03 1.53 1.03.9 1.53 2.36 1.09 2.94.83.09-.65.35-1.09.63-1.34-2.22-.25-4.55-1.11-4.55-4.94 0-1.09.39-1.98 1.03-2.68-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.02a9.6 9.6 0 0 1 5 0c1.91-1.29 2.75-1.02 2.75-1.02.55 1.38.2 2.4.1 2.65.64.7 1.03 1.59 1.03 2.68 0 3.84-2.34 4.69-4.57 4.94.36.31.68.92.68 1.85l-.01 2.75c0 .27.18.58.69.48A10 10 0 0 0 12 2z" />
    </svg>
    """
  end

  defp provider_icon(%{provider: "orcid"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class="size-5" fill="currentColor" aria-hidden="true">
      <path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 18.6A8.6 8.6 0 1 1 12 3.4a8.6 8.6 0 0 1 0 17.2z" />
      <circle cx="8.5" cy="7.7" r="1" />
      <path d="M7.8 10.1h1.4v7.3H7.8z" />
      <path d="M11.1 10.1h3.2c2.5 0 4 1.6 4 3.6 0 2.1-1.5 3.7-4 3.7h-3.2v-7.3zm1.4 1.3v4.7h1.7c1.7 0 2.6-1 2.6-2.4s-.9-2.3-2.6-2.3h-1.7z" />
    </svg>
    """
  end

  defp provider_icon(assigns) do
    ~H"""
    <span class="font-semibold">{label(@provider)}</span>
    """
  end
end
