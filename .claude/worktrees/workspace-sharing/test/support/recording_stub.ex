defmodule PerfectPaper.Chatbot.LLM.RecordingStub do
  @moduledoc "Test LLM adapter: records the composed system prompt it was handed, returns a canned review."
  @behaviour PerfectPaper.Chatbot.LLM

  @impl true
  def complete(_messages, _opts \\ []), do: {:ok, %{role: :assistant, content: "stub"}}

  @impl true
  def review(_text, system, _opts) do
    if pid = Application.get_env(:perfect_paper, :recording_stub_pid),
      do: send(pid, {:review_system, system})

    {:ok, %{overall_feedback: "ok", comments: []}}
  end
end
