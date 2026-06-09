defmodule PerfectPaper.ChatbotTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.{Chatbot, Repo}
  alias PerfectPaper.Chatbot.Conversation

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.ChatbotFixtures

  describe "review_document/3" do
    setup do
      %{scope: %{org_id: nil, owner_type: :user, owner_id: Ecto.UUID.generate()}}
    end

    test "a full review returns overall feedback and several comments", %{scope: scope} do
      assert {:ok, review} = Chatbot.review_document("some manuscript text", :full, scope)
      assert is_binary(review.overall_feedback)
      assert length(review.comments) > 1

      for comment <- review.comments do
        assert is_binary(comment.suggestion)
        assert is_integer(comment.position)
      end
    end

    test "a preview is a lighter pass — fewer, shallower comments", %{scope: scope} do
      assert {:ok, preview} = Chatbot.review_document("some manuscript text", :preview, scope)
      assert {:ok, full} = Chatbot.review_document("some manuscript text", :full, scope)

      assert preview.overall_feedback =~ "Preview"
      assert length(preview.comments) < length(full.comments)
    end
  end

  describe "open_conversation/2" do
    test "creates a conversation for a user" do
      user = user_fixture()
      assert {:ok, conversation} = Chatbot.open_conversation(user, %{title: "My Chat"})
      assert conversation.user_id == user.id
      assert conversation.title == "My Chat"
    end

    test "creates a conversation without a title" do
      user = user_fixture()
      assert {:ok, conversation} = Chatbot.open_conversation(user)
      assert conversation.user_id == user.id
      assert is_nil(conversation.title)
    end

    test "requires a user_id" do
      assert {:error, changeset} =
               Chatbot.open_conversation(%{id: nil}, %{title: "x"})

      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "post_user_message/2" do
    test "inserts a :user message in the conversation" do
      user = user_fixture()
      conversation = conversation_fixture(user)

      assert {:ok, message} = Chatbot.post_user_message(conversation, "Hello!")
      assert message.role == :user
      assert message.content == "Hello!"
      assert message.conversation_id == conversation.id
    end
  end

  describe "answer/1" do
    test "inserts an :assistant message with stub content" do
      user = user_fixture()
      conversation = conversation_fixture(user)
      {:ok, _} = Chatbot.post_user_message(conversation, "What is passive voice?")

      assert {:ok, reply} = Chatbot.answer(conversation)
      assert reply.role == :assistant
      assert reply.content == "This is a stubbed assistant response."
      assert reply.conversation_id == conversation.id
    end

    test "answer/1 works even with no prior messages" do
      user = user_fixture()
      conversation = conversation_fixture(user)

      assert {:ok, reply} = Chatbot.answer(conversation)
      assert reply.role == :assistant
    end
  end

  describe "delete_conversation/1" do
    test "removes the conversation" do
      user = user_fixture()
      conversation = conversation_fixture(user)

      assert {:ok, deleted} = Chatbot.delete_conversation(conversation)
      assert deleted.id == conversation.id
      assert is_nil(Repo.get(Conversation, conversation.id))
    end
  end
end
