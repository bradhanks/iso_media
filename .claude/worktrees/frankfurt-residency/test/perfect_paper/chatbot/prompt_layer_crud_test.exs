defmodule PerfectPaper.Chatbot.PromptLayerCrudTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Chatbot

  test "put then get round-trips a body" do
    sid = Ecto.UUID.generate()
    uid = Ecto.UUID.generate()
    assert {:ok, _} = Chatbot.put_prompt_layer(:organization, sid, "Use APA.", uid)
    assert Chatbot.get_prompt_layer(:organization, sid) == "Use APA."
  end

  test "put is an idempotent upsert on (scope, scope_id)" do
    sid = Ecto.UUID.generate()
    uid = Ecto.UUID.generate()
    {:ok, _} = Chatbot.put_prompt_layer(:user, sid, "first", uid)
    {:ok, _} = Chatbot.put_prompt_layer(:user, sid, "second", uid)
    assert Chatbot.get_prompt_layer(:user, sid) == "second"
    assert PerfectPaper.Repo.aggregate(PerfectPaper.Chatbot.PromptLayer, :count) == 1
  end

  test "get returns nil when absent; blank body stores nil" do
    sid = Ecto.UUID.generate()
    assert Chatbot.get_prompt_layer(:user, sid) == nil
    {:ok, _} = Chatbot.put_prompt_layer(:user, sid, "   ", sid)
    assert Chatbot.get_prompt_layer(:user, sid) == nil
  end

  test "rejects an over-length body" do
    assert {:error, %Ecto.Changeset{}} =
             Chatbot.put_prompt_layer(
               :user,
               Ecto.UUID.generate(),
               String.duplicate("x", 4001),
               Ecto.UUID.generate()
             )
  end
end
