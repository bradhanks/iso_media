defmodule PerfectPaper.Chatbot.Conversation do
  @moduledoc """
  A chat conversation between a writer and the PerfectPaper AI assistant.
  A conversation may optionally be anchored to a proofreading session for
  context-aware responses.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Chatbot.ChatMessage

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "conversations" do
    field :title, :string
    field :user_id, :binary_id
    field :session_id, :binary_id

    has_many :messages, ChatMessage

    timestamps(type: :utc_datetime)
  end

  @doc "Builds a changeset for creating a new conversation."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user_id, :session_id, :title])
    |> validate_required([:user_id])
  end
end
