defmodule PerfectPaper.Repo.Migrations.AddCanonicalToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :canonical_doc, :map
      add :canonical_meta, :map
      add :source_format, :string
    end
  end
end
