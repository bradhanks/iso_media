defmodule PerfectPaper.Repo.BackfillWorkspacesTest do
  @moduledoc """
  Exercises the BackfillWorkspaces migration's SQL directly against fixtures.
  (The migration itself ran at suite setup against an empty DB; running it via
  Ecto.Migrator inside the sandbox transaction is awkward, so we assert the same
  three statements here, which is what the migration executes.)
  """
  use PerfectPaper.DataCase, async: true

  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.{Repo, Workspaces, History}

  @insert_personal """
  INSERT INTO workspaces (id, name, is_personal, user_id, inserted_at, updated_at)
  SELECT gen_random_uuid(), 'Personal', true, u.id, now(), now()
  FROM users u
  WHERE NOT EXISTS (
    SELECT 1 FROM workspaces w WHERE w.user_id = u.id AND w.is_personal
  )
  """

  @stamp_sessions """
  UPDATE history_sessions s
  SET workspace_id = w.id
  FROM workspaces w
  WHERE w.user_id = s.owner_id
    AND w.is_personal
    AND s.owner_type = 'user'
    AND s.workspace_id IS NULL
  """

  @default_active """
  UPDATE users u
  SET active_workspace_id = w.id
  FROM workspaces w
  WHERE w.user_id = u.id
    AND w.is_personal
    AND u.active_workspace_id IS NULL
  """

  test "backfill gives every user a Personal workspace and stamps their sessions" do
    user = user_fixture()

    {:ok, session} =
      History.begin_session(%{user_id: user.id, title: "legacy", workspace_id: nil})

    assert Repo.reload!(session).workspace_id == nil

    Repo.query!(@insert_personal)
    Repo.query!(@stamp_sessions)
    Repo.query!(@default_active)

    personal = Workspaces.personal_workspace(user)
    assert personal.is_personal
    assert Repo.reload!(session).workspace_id == personal.id
    assert Repo.reload!(user).active_workspace_id == personal.id
  end

  test "backfill is idempotent — re-running creates no duplicate Personal" do
    user = user_fixture()
    Repo.query!(@insert_personal)
    Repo.query!(@insert_personal)

    assert Workspaces.list_workspaces(user) |> Enum.count(& &1.is_personal) == 1
  end
end
