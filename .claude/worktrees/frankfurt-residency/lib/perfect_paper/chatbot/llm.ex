defmodule PerfectPaper.Chatbot.LLM do
  @moduledoc """
  Behaviour for the language model adapter.

  The adapter is the only module that communicates with an external LLM provider.
  Select the active adapter at runtime via:

      config :perfect_paper, :llm_provider, PerfectPaper.Chatbot.LLM.Stub

  ## Message format

  `complete/1` receives the full message history as a list of maps with atom keys:

      [
        %{role: :system,    content: "You are a helpful academic writing assistant."},
        %{role: :user,      content: "What does passive voice mean?"},
        %{role: :assistant, content: "Passive voice is..."},
        %{role: :user,      content: "Can you give an example?"}
      ]

  Each map MUST have:
  - `:role` — one of `:user`, `:assistant`, or `:system`
  - `:content` — the message text as a `String.t()`

  `opts` carries `:locale` (default `"en"`); the adapter appends a language
  directive so generated feedback is written in the user's language.
  """

  @doc """
  Sends the message history to the language model and returns the assistant's reply.

  `opts` may carry `:locale` (default `"en"`).

  Returns `{:ok, %{role: :assistant, content: String.t()}}` on success,
  or `{:error, term()}` on failure.
  """
  @callback complete([%{role: atom(), content: String.t()}], opts :: keyword()) ::
              {:ok, %{role: :assistant, content: String.t()}} | {:error, term()}

  @typedoc "The agentic processing level a review runs at."
  @type level :: :preview | :full

  @doc """
  Reviews a manuscript given a fully composed `system` prompt. `opts` may carry
  `:level` (the adapter may ignore it) and `:locale` (the adapter appends a
  language directive so feedback is written in the reader's language). Returns
  atom-keyed comment maps matching `PerfectPaper.History.Comment` fields.
  """
  @callback review(text :: String.t(), system :: String.t(), opts :: keyword()) ::
              {:ok, %{overall_feedback: String.t(), comments: [map()]}} | {:error, term()}
end
