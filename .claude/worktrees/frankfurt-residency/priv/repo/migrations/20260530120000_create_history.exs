defmodule PerfectPaper.Repo.Migrations.CreateHistory do
  use Ecto.Migration

  def change do
    create table(:history_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :processing_status, :string, null: false, default: "pending"
      add :is_public, :boolean, null: false, default: false
      add :viewed, :boolean, null: false, default: false
      add :overall_feedback, :text
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:history_sessions, [:user_id])

    create table(:comments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :original_text, :text
      add :suggestion, :text
      add :explanation, :text
      add :category, :string
      add :status, :string, null: false, default: "open"
      add :position, :integer

      add :session_id, references(:history_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:comments, [:session_id])

    create table(:comment_actions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action_type, :string, null: false

      add :session_id, references(:history_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :comment_id, references(:comments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:comment_actions, [:comment_id])
    create unique_index(:comment_actions, [:comment_id, :action_type])
  end
end
