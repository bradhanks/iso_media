defmodule PerfectPaper.Chatbot.ReviewComposeTest do
  use PerfectPaper.DataCase, async: false

  alias PerfectPaper.Chatbot

  setup do
    prev = Application.get_env(:perfect_paper, :llm_provider)
    Application.put_env(:perfect_paper, :recording_stub_pid, self())
    Application.put_env(:perfect_paper, :llm_provider, PerfectPaper.Chatbot.LLM.RecordingStub)

    on_exit(fn ->
      Application.put_env(:perfect_paper, :llm_provider, prev)
      Application.delete_env(:perfect_paper, :recording_stub_pid)
    end)

    :ok
  end

  test "review_document/3 composes org + owner layers (+ hardening) into the system prompt" do
    org_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    {:ok, _} = Chatbot.put_prompt_layer(:organization, org_id, "Org: use APA.", user_id)
    {:ok, _} = Chatbot.put_prompt_layer(:user, user_id, "Owner: focus on methods.", user_id)

    assert {:ok, %{comments: []}} =
             Chatbot.review_document("manuscript", :full, %{
               org_id: org_id,
               owner_type: :user,
               owner_id: user_id
             })

    assert_received {:review_system, system}
    assert system =~ "<tenant_custom_rules>"
    assert system =~ "Org: use APA."
    assert system =~ "Owner: focus on methods."
    assert system =~ "<absolute_constraints>"
  end

  test "no layers → no tenant block" do
    assert {:ok, _} =
             Chatbot.review_document("m", :preview, %{
               org_id: nil,
               owner_type: :user,
               owner_id: Ecto.UUID.generate()
             })

    assert_received {:review_system, system}
    refute system =~ "<tenant_custom_rules>"
  end
end
