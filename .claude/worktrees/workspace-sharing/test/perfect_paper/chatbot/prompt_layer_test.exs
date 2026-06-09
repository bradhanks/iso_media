defmodule PerfectPaper.Chatbot.PromptLayerTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Chatbot.PromptLayer

  test "valid changeset" do
    cs =
      PromptLayer.changeset(%PromptLayer{}, %{
        scope: :organization,
        scope_id: Ecto.UUID.generate(),
        body: "Use APA.",
        updated_by_id: Ecto.UUID.generate()
      })

    assert cs.valid?
  end

  test "blank/whitespace body becomes nil (cleared = off)" do
    cs =
      PromptLayer.changeset(%PromptLayer{}, %{
        scope: :user,
        scope_id: Ecto.UUID.generate(),
        body: "   \n  "
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :body) == nil
  end

  test "requires scope and scope_id; body optional" do
    cs = PromptLayer.changeset(%PromptLayer{}, %{})
    refute cs.valid?
    assert %{scope: _, scope_id: _} = errors_on(cs)
  end

  test "rejects an over-length body" do
    cs =
      PromptLayer.changeset(%PromptLayer{}, %{
        scope: :user,
        scope_id: Ecto.UUID.generate(),
        body: String.duplicate("x", 4001)
      })

    refute cs.valid?
    assert %{body: [_ | _]} = errors_on(cs)
  end
end
