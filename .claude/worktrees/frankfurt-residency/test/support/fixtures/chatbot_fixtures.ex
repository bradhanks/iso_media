defmodule PerfectPaper.ChatbotFixtures do
  @moduledoc "Test fixtures for the Chatbot context."

  alias PerfectPaper.Chatbot

  import PerfectPaper.AccountsFixtures, only: [user_fixture: 0]

  @doc "Creates a conversation for the given user (or a fresh one if omitted)."
  def conversation_fixture(user \\ nil, attrs \\ %{}) do
    user = user || user_fixture()
    {:ok, conversation} = Chatbot.open_conversation(user, attrs)
    conversation
  end
end
