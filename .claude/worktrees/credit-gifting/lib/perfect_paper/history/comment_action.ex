defmodule PerfectPaper.History.CommentAction do
  @moduledoc """
  An action a writer took on a piece of feedback: dismissed it or marked it
  addressed. Recording the action lets the writer undo it later.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "comment_actions" do
    field :action_type, Ecto.Enum, values: [:dismiss, :address]
    field :session_id, :binary_id
    field :comment_id, :binary_id
    field :user_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds a changeset recording a writer's action on a comment."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(action, attrs) do
    action
    |> cast(attrs, [:action_type, :session_id, :comment_id, :user_id])
    |> validate_required([:action_type, :session_id, :comment_id, :user_id])
    |> unique_constraint([:comment_id, :action_type],
      name: :comment_actions_comment_id_action_type_index
    )
  end
end
