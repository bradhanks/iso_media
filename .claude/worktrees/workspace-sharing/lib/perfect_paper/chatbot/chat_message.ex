defmodule PerfectPaper.Chatbot.ChatMessage do
  @moduledoc """
  A single message in a chat conversation. Each message has a role
  (`:user`, `:assistant`, or `:system`) and text content.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Chatbot.Conversation

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "chat_messages" do
    field :role, Ecto.Enum, values: [:user, :assistant, :system]
    field :content, :string

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime)
  end

  @doc "Builds a changeset for inserting a new chat message."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(message, attrs) do
    message
    |> cast(attrs, [:role, :content, :conversation_id])
    |> validate_required([:role, :content, :conversation_id])
  end
end
