defmodule PerfectPaper.History.CommentTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.History.Comment

  test "create_changeset (AI) sets author_type :ai" do
    cs =
      Comment.create_changeset(%Comment{}, %{
        session_id: Ecto.UUID.generate(),
        original_text: "teh",
        suggestion: "the"
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :author_type) == :ai
  end

  test "author_changeset requires session_id, author_id, body and sets author_type :user" do
    cs = Comment.author_changeset(%Comment{}, %{})
    refute cs.valid?
    errors = errors_on(cs)
    assert Map.has_key?(errors, :session_id)
    assert Map.has_key?(errors, :author_id)
    assert Map.has_key?(errors, :body)

    ok =
      Comment.author_changeset(%Comment{}, %{
        session_id: Ecto.UUID.generate(),
        author_id: Ecto.UUID.generate(),
        body: "nice point"
      })

    assert ok.valid?
    assert Ecto.Changeset.get_field(ok, :author_type) == :user
  end

  test "author_changeset accepts a parent_id" do
    pid = Ecto.UUID.generate()

    cs =
      Comment.author_changeset(%Comment{}, %{
        session_id: Ecto.UUID.generate(),
        author_id: Ecto.UUID.generate(),
        body: "reply",
        parent_id: pid
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :parent_id) == pid
  end
end
