defmodule PerfectPaper.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS ltree", "DROP EXTENSION IF EXISTS ltree"

    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :parent_id, references(:groups, type: :binary_id, on_delete: :delete_all)
      add :name, :string, null: false
      add :kind, :string, null: false, default: "group"
      # ltree materialized path, stored as text; queried via path::ltree (see plan).
      add :path, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:groups, [:organization_id])
    create index(:groups, [:parent_id])

    # Expression GiST index so `path::ltree <@ ...` subtree queries stay fast.
    execute(
      "CREATE INDEX groups_path_gist_idx ON groups USING GIST ((path::ltree))",
      "DROP INDEX groups_path_gist_idx"
    )
  end
end
