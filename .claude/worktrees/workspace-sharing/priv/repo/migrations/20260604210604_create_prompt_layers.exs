defmodule PerfectPaper.Repo.Migrations.CreatePromptLayers do
  use Ecto.Migration

  def change do
    create table(:prompt_layers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string, null: false
      add :scope_id, :binary_id, null: false
      add :body, :text
      add :updated_by_id, :binary_id
      timestamps(type: :utc_datetime)
    end

    create unique_index(:prompt_layers, [:scope, :scope_id])
  end
end
