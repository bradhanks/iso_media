defmodule PerfectPaper.Repo.Migrations.AddCommentAuthorship do
  use Ecto.Migration

  def up do
    alter table(:comments) do
      add :author_type, :string
      add :author_id, :binary_id
      add :body, :text
      add :parent_id, references(:comments, type: :binary_id, on_delete: :nilify_all)
    end

    execute "UPDATE comments SET author_type = 'ai' WHERE author_type IS NULL"
    alter table(:comments), do: modify(:author_type, :string, null: false)
    create index(:comments, [:parent_id])
  end

  def down do
    drop index(:comments, [:parent_id])

    alter table(:comments) do
      remove :author_type
      remove :author_id
      remove :body
      remove :parent_id
    end
  end
end
