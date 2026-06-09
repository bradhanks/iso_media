defmodule PerfectPaper.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :content_type, :string
      add :byte_size, :integer
      add :status, :string, null: false, default: "pending"
      add :storage_key, :string

      add :parent_document_id,
          references(:documents, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:documents, [:user_id])
    create index(:documents, [:parent_document_id])
  end
end
