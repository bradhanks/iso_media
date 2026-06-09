defmodule PerfectPaper.Repo.Migrations.MakeSessionUserIdNullable do
  use Ecto.Migration

  def up do
    # Group-owned sessions have no user_id — the owner is captured by the
    # polymorphic owner_type / owner_id columns added in 20260602100200.
    execute "ALTER TABLE history_sessions ALTER COLUMN user_id DROP NOT NULL"
  end

  def down do
    execute "ALTER TABLE history_sessions ALTER COLUMN user_id SET NOT NULL"
  end
end
