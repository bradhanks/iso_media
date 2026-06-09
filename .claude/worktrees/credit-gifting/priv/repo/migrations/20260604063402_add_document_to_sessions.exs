defmodule PerfectPaper.Repo.Migrations.AddDocumentToSessions do
  use Ecto.Migration

  def change do
    alter table(:history_sessions) do
      add :document_id, references(:documents, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:history_sessions, [:document_id])
  end
end
