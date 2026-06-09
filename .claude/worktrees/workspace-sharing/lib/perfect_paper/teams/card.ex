defmodule PerfectPaper.Teams.Card do
  @moduledoc "Renders Adaptive Cards (v1.4) for proactive notifications and command replies."

  @schema "http://adaptivecards.io/schemas/adaptive-card.json"

  @doc "Wraps a list of card body elements as a v1.4 Adaptive Card attachment payload."
  @spec card([map()]) :: map()
  def card(body) when is_list(body) do
    %{
      "type" => "AdaptiveCard",
      "$schema" => @schema,
      "version" => "1.4",
      "body" => body
    }
  end

  @spec text_block(String.t(), keyword()) :: map()
  def text_block(text, opts \\ []) do
    %{"type" => "TextBlock", "text" => text, "wrap" => true}
    |> then(fn b -> if opts[:weight], do: Map.put(b, "weight", opts[:weight]), else: b end)
  end

  @doc "Welcome card shown when a user links."
  @spec welcome(String.t()) :: map()
  def welcome(name) do
    card([
      text_block("You're connected, #{name}.", weight: "Bolder"),
      text_block(
        "I'll let you know when your reviews are ready. Try `status`, `help`, or `mute`."
      )
    ])
  end

  @doc "Link-code card (fallback): a button deep-linking to the web app to finish linking."
  @spec link_prompt(String.t()) :: map()
  def link_prompt(url) do
    %{
      "type" => "AdaptiveCard",
      "$schema" => @schema,
      "version" => "1.4",
      "body" => [text_block("Connect your PerfectPaper account to finish setup.")],
      "actions" => [
        %{"type" => "Action.OpenUrl", "title" => "Connect PerfectPaper", "url" => url}
      ]
    }
  end

  @spec help() :: map()
  def help do
    card([
      text_block("PerfectPaper commands", weight: "Bolder"),
      text_block(
        "`status` — your recent reviews\n`mute` / `unmute` — toggle notifications\n`help` — this message"
      )
    ])
  end

  @doc "Proactive event card. `event_type` is the Events type; `data` carries the title/etc."
  @spec event(atom(), map()) :: map()
  def event(:"session.completed", %{title: title}),
    do: card([text_block("Your review is ready", weight: "Bolder"), text_block(title)])

  def event(:"comment.added", %{title: title}),
    do: card([text_block("New comment on your manuscript", weight: "Bolder"), text_block(title)])

  def event(:"session.shared", %{title: title}),
    do:
      card([text_block("A manuscript was shared with you", weight: "Bolder"), text_block(title)])

  @doc "Status card listing recent session titles + states."
  @spec status([%{title: String.t(), state: String.t()}]) :: map()
  def status([]), do: card([text_block("No recent reviews.")])

  def status(sessions) do
    lines = Enum.map_join(sessions, "\n", fn s -> "• #{s.title} — #{s.state}" end)
    card([text_block("Your recent reviews", weight: "Bolder"), text_block(lines)])
  end
end
