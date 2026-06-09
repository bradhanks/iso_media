defmodule PerfectPaper.Repo.Migrations.BackfillWorkspaces do
  use Ecto.Migration

  def up do
    # 1) One Personal workspace per existing user that lacks one.
    execute """
    INSERT INTO workspaces (id, name, is_personal, user_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'Personal', true, u.id, now(), now()
    FROM users u
    WHERE NOT EXISTS (
      SELECT 1 FROM workspaces w WHERE w.user_id = u.id AND w.is_personal
    )
    """

    # 2) Stamp existing user-owned sessions with that user's Personal workspace.
    execute """
    UPDATE history_sessions s
    SET workspace_id = w.id
    FROM workspaces w
    WHERE w.user_id = s.owner_id
      AND w.is_personal
      AND s.owner_type = 'user'
      AND s.workspace_id IS NULL
    """

    # 3) Default each user's last-used workspace to Personal.
    execute """
    UPDATE users u
    SET active_workspace_id = w.id
    FROM workspaces w
    WHERE w.user_id = u.id
      AND w.is_personal
      AND u.active_workspace_id IS NULL
    """
  end

  def down do
    execute "UPDATE users SET active_workspace_id = NULL"
    execute "UPDATE history_sessions SET workspace_id = NULL"
    execute "DELETE FROM workspaces WHERE is_personal"
  end
end
