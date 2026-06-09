defmodule PerfectPaper.Chatbot.LLM.AnthropicLocaleTest do
  # async: false — mutates the global Application env for the Anthropic adapter,
  # which the (also-global) anthropic_test does too; running them concurrently
  # would race on that shared config.
  use ExUnit.Case, async: false

  alias PerfectPaper.Chatbot.LLM.Anthropic

  # Stubs the Anthropic Messages API via Req's `:plug` option and echoes the
  # decoded request body back so we can assert what system prompt was sent.
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

  test "complete/2 appends the language directive for a non-English locale" do
    configure(%{"content" => [%{"type" => "text", "text" => "ok"}]})

    Anthropic.complete([%{role: :user, content: "hi"}], locale: "de")

    assert_received {:request, %{"system" => system}}
    assert system =~ "Deutsch"
  end

  test "complete/2 omits the directive for English" do
    configure(%{"content" => [%{"type" => "text", "text" => "ok"}]})

    Anthropic.complete([%{role: :user, content: "hi"}], locale: "en")

    assert_received {:request, %{"system" => system}}
    refute system =~ "locale"
  end

  test "review/3 appends the language directive for a non-English locale" do
    configure(%{
      "content" => [
        %{
          "type" => "tool_use",
          "name" => "submit_review",
          "input" => %{"overall_feedback" => "ok", "comments" => []}
        }
      ]
    })

    Anthropic.review("some manuscript", "You are an expert peer reviewer.", locale: "fr")

    assert_received {:request, %{"system" => system}}
    assert system =~ "Français"
  end
end
