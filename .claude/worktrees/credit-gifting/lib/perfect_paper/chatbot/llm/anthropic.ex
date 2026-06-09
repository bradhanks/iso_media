defmodule PerfectPaper.Chatbot.LLM.Anthropic do
  @moduledoc """
  Live LLM adapter backed by Anthropic's Messages API.

  This is the only module that knows the Anthropic wire format — its endpoint,
  headers, request body, tool-use shape, and error codes. Nothing vendor-specific
  leaks past it: callers see the behaviour's plain `{:ok, ...}` / `{:error, atom}`
  contract, and the structured review is validated through a changeset before it
  is handed back (so the DB layer never sees a malformed result).

  ## Configuration

      config :perfect_paper, PerfectPaper.Chatbot.LLM.Anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        model: "claude-haiku-4-5"

  `config/runtime.exs` selects this adapter automatically whenever
  `ANTHROPIC_API_KEY` is set (outside the test environment); otherwise the Stub
  stays in place. The `:model` defaults to `claude-haiku-4-5` and is overridable.
  A `:req_options` keyword list is merged into the `Req` request (used by tests to
  inject a stub plug).
  """
  @behaviour PerfectPaper.Chatbot.LLM

  require Logger

  @base_url "https://api.anthropic.com"
  @api_version "2023-06-01"
  @default_model "claude-haiku-4-5"
  @max_tokens 8192
  @review_tool "submit_review"

  @chat_system """
  You are PerfectPaper, an AI peer reviewer for academic papers. Your voice is \
  measured, warm, and scholarly. Answer the writer's questions about their \
  manuscript and the feedback on it clearly and concisely, the way a generous \
  senior colleague would.
  """

  @impl true
  @spec complete([%{role: atom(), content: String.t()}], keyword()) ::
          {:ok, %{role: :assistant, content: String.t()}} | {:error, term()}
  def complete(messages, opts \\ []) when is_list(messages) do
    {system, turns} = split_system(messages)

    body = %{
      model: model(),
      max_tokens: @max_tokens,
      system: with_language(prepend(@chat_system, system), opts),
      messages: turns
    }

    with {:ok, %{"content" => content}} <- request(body) do
      case extract_text(content) do
        "" -> unexpected(content)
        text -> {:ok, %{role: :assistant, content: text}}
      end
    end
  end

  @impl true
  @spec review(String.t(), String.t(), keyword()) ::
          {:ok, %{overall_feedback: String.t(), comments: [map()]}} | {:error, term()}
  def review(text, system, opts \\ []) when is_binary(text) and is_binary(system) do
    body = %{
      model: model(),
      max_tokens: @max_tokens,
      system: with_language(system, opts),
      tools: [review_tool_schema()],
      tool_choice: %{type: "tool", name: @review_tool},
      messages: [%{role: "user", content: "Review the following manuscript:\n\n" <> text}]
    }

    with {:ok, %{"content" => content}} <- request(body) do
      case extract_tool_input(content, @review_tool) do
        nil -> unexpected(content)
        input -> validate_review(input)
      end
    end
  end

  # ── Request / transport ─────────────────────────────────────────────────────

  defp request(body) do
    case api_key() do
      key when is_binary(key) and key != "" ->
        case Req.post(req(key), url: "/v1/messages", json: body) do
          {:ok, %{status: 200, body: response}} ->
            {:ok, response}

          {:ok, %{status: status, body: response}} ->
            Logger.error("Anthropic API returned #{status}: #{inspect(response)}")
            {:error, :llm_request_failed}

          {:error, reason} ->
            Logger.error("Anthropic API request failed: #{inspect(reason)}")
            {:error, :llm_request_failed}
        end

      _ ->
        Logger.error("Anthropic adapter selected but no API key is configured")
        {:error, :missing_api_key}
    end
  end

  defp req(key) do
    Req.new(
      base_url: @base_url,
      headers: [
        {"x-api-key", key},
        {"anthropic-version", @api_version},
        {"content-type", "application/json"}
      ],
      receive_timeout: 120_000
    )
    |> Req.merge(config()[:req_options] || [])
  end

  # ── Request shaping ─────────────────────────────────────────────────────────

  # Splits a behaviour-format history into the top-level system prompt (Anthropic
  # carries system separately) and the user/assistant turns.
  defp split_system(messages) do
    {system, turns} = Enum.split_with(messages, &(&1.role == :system))

    system_text = system |> Enum.map_join("\n\n", & &1.content)
    turns = Enum.map(turns, &%{role: to_string(&1.role), content: &1.content})

    {system_text, turns}
  end

  defp prepend(base, ""), do: String.trim(base)
  defp prepend(base, extra), do: String.trim(base) <> "\n\n" <> extra

  # Appends the user's-language directive (nil for English) so the model writes
  # its feedback in the reader's language.
  defp with_language(system, opts) do
    case PerfectPaper.Localization.language_directive(opts[:locale] || "en") do
      nil -> system
      directive -> system <> "\n\n" <> directive
    end
  end

  defp review_tool_schema do
    %{
      name: @review_tool,
      description: "Submit the manuscript review: overall feedback plus per-passage comments.",
      input_schema: %{
        type: "object",
        properties: %{
          overall_feedback: %{
            type: "string",
            description: "A short editorial summary of the manuscript's standing."
          },
          comments: %{
            type: "array",
            description: "Individual pieces of feedback, each anchored to the manuscript.",
            items: %{
              type: "object",
              properties: %{
                category: %{
                  type: "string",
                  description: "e.g. methods, statistics, claims, data, clarity, structure."
                },
                suggestion: %{type: "string", description: "The concrete change to make."},
                original_text: %{
                  type: ["string", "null"],
                  description: "The quoted passage, or null for a general note."
                },
                explanation: %{
                  type: ["string", "null"],
                  description: "Why it matters / how to address it."
                }
              },
              required: ["category", "suggestion"]
            }
          }
        },
        required: ["overall_feedback", "comments"]
      }
    }
  end

  # ── Response parsing ──────────────────────────────────────────────────────────

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp extract_text(_), do: ""

  defp extract_tool_input(content, name) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "tool_use", "name" => ^name, "input" => input} -> input
      _ -> nil
    end)
  end

  defp extract_tool_input(_, _), do: nil

  defp unexpected(content) do
    Logger.error("Anthropic returned an unexpected response shape: #{inspect(content)}")
    {:error, :unexpected_response}
  end

  # ── Result validation (changeset on adapter output) ───────────────────────────

  # Validates the model's structured review through a schemaless changeset before
  # returning it, so a malformed tool result fails fast rather than reaching the DB.
  defp validate_review(input) do
    types = %{overall_feedback: :string}

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(%{"overall_feedback" => input["overall_feedback"]}, [
        :overall_feedback
      ])
      |> Ecto.Changeset.validate_required([:overall_feedback])

    if changeset.valid? do
      {:ok,
       %{
         overall_feedback: input["overall_feedback"],
         comments: build_comments(input["comments"])
       }}
    else
      {:error, :invalid_review}
    end
  end

  defp build_comments(comments) when is_list(comments) do
    comments
    |> Enum.with_index(1)
    |> Enum.map(fn {comment, position} ->
      %{
        position: position,
        category: comment["category"],
        suggestion: comment["suggestion"],
        original_text: comment["original_text"],
        explanation: comment["explanation"]
      }
    end)
  end

  defp build_comments(_), do: []

  # ── Config ────────────────────────────────────────────────────────────────────

  defp config, do: Application.get_env(:perfect_paper, __MODULE__, [])
  defp api_key, do: config()[:api_key] || System.get_env("ANTHROPIC_API_KEY")
  defp model, do: config()[:model] || @default_model
end
