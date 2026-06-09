defmodule PerfectPaper.History.Session do
  @moduledoc """
  A proofreading session: one manuscript reviewed by PerfectPaper, carrying its
  processing status, overall feedback, sharing/viewed flags, and its comments.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.History.Comment

  @type t :: %__MODULE__{}

  @statuses [:pending, :converting, :analyzing, :complete, :failed]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "history_sessions" do
    field :title, :string
    field :processing_status, Ecto.Enum, values: @statuses, default: :pending
    field :is_public, :boolean, default: false
    field :viewed, :boolean, default: false
    field :overall_feedback, :string
    field :processing_level, Ecto.Enum, values: [:preview, :full]
    field :user_id, :binary_id
    field :owner_type, Ecto.Enum, values: [:user, :group]
    field :owner_id, :binary_id
    field :organization_id, :binary_id
    field :owner_path, :string
    field :document_id, :binary_id
    field :workspace_id, :binary_id

    has_many :comments, Comment

    # Populated by list_session_summaries/2 for the index; nil otherwise.
    field :comments_count, :integer, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Begins a session for a writer's uploaded manuscript."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :title,
      :user_id,
      :processing_status,
      :owner_type,
      :owner_id,
      :organization_id,
      :owner_path,
      :document_id,
      :workspace_id
    ])
    |> validate_required([:owner_type, :owner_id])
  end

  @doc "Stores the overall feedback + processing level and marks the review complete."
  @spec complete_changeset(t(), map()) :: Ecto.Changeset.t()
  def complete_changeset(session, attrs) do
    session
    |> cast(attrs, [:overall_feedback, :processing_level])
    |> put_change(:processing_status, :complete)
  end

  @doc "Renames the manuscript — the human title shown at the top of the workspace."
  @spec title_changeset(t(), map()) :: Ecto.Changeset.t()
  def title_changeset(session, attrs) do
    session
    |> cast(attrs, [:title])
    |> update_change(:title, &trim/1)
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 300)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  @doc "Updates the sharing/viewed flags."
  @spec flags_changeset(t(), map()) :: Ecto.Changeset.t()
  def flags_changeset(session, attrs) do
    cast(session, attrs, [:is_public, :viewed])
  end
end
