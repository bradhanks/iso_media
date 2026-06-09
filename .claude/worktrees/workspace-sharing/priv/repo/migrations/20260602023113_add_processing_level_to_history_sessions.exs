defmodule PerfectPaper.Repo.Migrations.AddProcessingLevelToHistorySessions do
  use Ecto.Migration

  def change do
    alter table(:history_sessions) do
      # The agentic processing level a review ran at: :preview (free, throttled)
      # or :full (paid). Stored as a string via Ecto.Enum.
      add :processing_level, :string
    end
  end
end
