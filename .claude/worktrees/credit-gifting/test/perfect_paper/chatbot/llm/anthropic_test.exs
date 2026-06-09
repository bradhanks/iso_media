defmodule PerfectPaper.Chatbot.LLM.AnthropicTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Chatbot.LLM.Anthropic
  alias PerfectPaper.Chatbot.Prompt

  # Stubs the Anthropic Messages API via Req's `:plug` option. The plug echoes the
  # decoded request body back to the test process so we can assert what the adapter
  # sent, then returns `response`. No network, no real key.
  defp configure(response) do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(body)})
      Req.Test.json(conn, response)
    end

    Application.put_env(:perfect_paper, Anthropic,
      api_key: "test-key",
      model: "claude-haiku-4-5",
      req_options: [plug: plug]
    )

    on_exit(fn -> Application.delete_env(:perfect_paper, Anthropic) end)
  end

  describe "complete/1" do
    test "sends history to the Messages API and returns the assistant text" do
      configure(%{"content" => [%{"type" => "text", "text" => "Passive voice is..."}]})

      assert {:ok, %{role: :assistant, content: "Passive voice is..."}} =
               Anthropic.complete([%{role: :user, content: "What is passive voice?"}])

      assert_received {:request, body}
      assert body["model"] == "claude-haiku-4-5"
      assert body["messages"] == [%{"role" => "user", "content" => "What is passive voice?"}]
      # A scholarly peer-reviewer persona is always supplied as the system prompt.
      assert is_binary(body["system"]) and body["system"] =~ "PerfectPaper"
    end

    test "hoists :system messages out of the turn list into the top-level system prompt" do
      configure(%{"content" => [%{"type" => "text", "text" => "ok"}]})

      assert {:ok, _} =
               Anthropic.complete([
                 %{role: :system, content: "Be terse."},
                 %{role: :user, content: "Hi"}
               ])

      assert_received {:request, body}
      # Anthropic takes only user/assistant turns in `messages`; system is top-level.
      assert body["messages"] == [%{"role" => "user", "content" => "Hi"}]
      assert body["system"] =~ "Be terse."
    end

    test "maps a non-200 response to a vendor-agnostic error" do
      Application.put_env(:perfect_paper, Anthropic,
        api_key: "test-key",
        req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end]
      )

      on_exit(fn -> Application.delete_env(:perfect_paper, Anthropic) end)

      assert {:error, :llm_request_failed} =
               Anthropic.complete([%{role: :user, content: "Hi"}])
    end
  end

  describe "review/3" do
    @tool_response %{
      "content" => [
        %{
          "type" => "tool_use",
          "name" => "submit_review",
          "input" => %{
            "overall_feedback" => "Strong contribution; tighten the causal claims.",
            "comments" => [
              %{
                "category" => "methods",
                "suggestion" => "Name the adjustment set",
                "original_text" => "directed acyclic graphs",
                "explanation" => "State the backdoor paths being closed."
              },
              %{
                "category" => "claims",
                "suggestion" => "Soften causal language",
                "original_text" => "drive refusal",
                "explanation" => "Design supports association, not causation."
              }
            ]
          }
        }
      ]
    }

    test "returns overall feedback and atom-keyed, positioned comments" do
      configure(@tool_response)

      assert {:ok, %{overall_feedback: feedback, comments: comments}} =
               Anthropic.review(
                 "A manuscript on vaccine hesitancy.",
                 Prompt.compose(:full),
                 level: :full
               )

      assert feedback =~ "causal claims"

      assert [
               %{
                 position: 1,
                 category: "methods",
                 suggestion: "Name the adjustment set",
                 original_text: "directed acyclic graphs",
                 explanation: "State the backdoor paths being closed."
               },
               %{position: 2, category: "claims"} | _
             ] = comments
    end

    test "a full review forces the submit_review tool" do
      configure(@tool_response)

      Anthropic.review("manuscript", Prompt.compose(:full), level: :full)

      assert_received {:request, body}
      assert body["tool_choice"] == %{"type" => "tool", "name" => "submit_review"}
      assert [%{"name" => "submit_review"}] = body["tools"]
      # The adapter forwards the composed system prompt verbatim.
      assert body["system"] =~ "thorough"
    end

    test "a preview review asks for a lighter pass" do
      configure(@tool_response)

      Anthropic.review("manuscript", Prompt.compose(:preview), level: :preview)

      assert_received {:request, body}
      assert String.downcase(body["system"]) =~ "preview"
    end

    test "rejects a structured result missing overall feedback" do
      configure(%{
        "content" => [
          %{"type" => "tool_use", "name" => "submit_review", "input" => %{"comments" => []}}
        ]
      })

      assert {:error, :invalid_review} =
               Anthropic.review("manuscript", Prompt.compose(:full), level: :full)
    end

    test "maps an unexpected response shape to a vendor-agnostic error" do
      configure(%{"content" => [%{"type" => "text", "text" => "no tool call here"}]})

      assert {:error, :unexpected_response} =
               Anthropic.review("manuscript", Prompt.compose(:full), level: :full)
    end
  end
end
