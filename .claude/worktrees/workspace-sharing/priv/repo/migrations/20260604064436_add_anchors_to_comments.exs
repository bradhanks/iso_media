defmodule PerfectPaper.Repo.Migrations.AddAnchorsToComments do
  use Ecto.Migration

  def change do
    alter table(:comments) do
      add :anchor_node_id, :string
      add :anchor_from, :integer
      add :anchor_to, :integer
    end
  end
end
