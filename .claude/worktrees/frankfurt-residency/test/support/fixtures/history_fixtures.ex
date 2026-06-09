defmodule PerfectPaper.HistoryFixtures do
  @moduledoc "Test fixtures for the History context."

  alias PerfectPaper.{History, Repo}

  import PerfectPaper.AccountsFixtures, only: [user_fixture: 0]

  @doc """
  Creates a session. Defaults to a fresh user as owner. Pass `group: %Group{}`
  (and the path is taken from it) to create a group-owned session.
  """
  def session_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    case attrs[:group] do
      nil ->
        user = attrs[:user] || user_fixture()

        {:ok, s} =
          History.begin_session(%{
            user_id: user.id,
            title: attrs[:title] || "Doc",
            workspace_id: attrs[:workspace_id]
          })

        s

      group ->
        {:ok, s} =
          History.begin_session(%{
            owner_type: :group,
            owner_id: group.id,
            organization_id: group.organization_id,
            owner_path: group.path,
            title: attrs[:title] || "Doc"
          })

        s
    end
  end

  @doc "Creates an open comment on the given session."
  def comment_fixture(session, attrs \\ %{}) do
    attrs = Map.new(attrs)

    {:ok, comment} =
      %PerfectPaper.History.Comment{session_id: session.id}
      |> Ecto.Changeset.change(
        Map.merge(
          %{original_text: "teh", suggestion: "the", status: :open},
          attrs
        )
      )
      |> Repo.insert()

    comment
  end
end
