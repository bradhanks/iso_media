defmodule PerfectPaper.Chatbot do
  @moduledoc """
  AI chat assistant — lets a writer open a conversation, post messages, and
  receive AI-generated replies grounded in their manuscript session (optional).

  This is the public API and the only `Repo`/IO boundary for the Chatbot context.
  """
  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.Chatbot.{Conversation, ChatMessage, PromptLayer, Prompt}

  # ── Conversations ───────────────────────────────────────────────────────────

  @doc "Opens a new conversation for a writer, optionally anchored to a session."
  @spec open_conversation(struct(), map()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def open_conversation(user, attrs \\ %{}) do
    attrs = Map.merge(Map.new(attrs), %{user_id: user.id})
    %Conversation{} |> Conversation.create_changeset(attrs) |> Repo.insert()
  end

  @doc "Permanently removes a conversation and all its messages."
  @spec delete_conversation(Conversation.t()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def delete_conversation(%Conversation{} = conversation), do: Repo.delete(conversation)

  # ── Messaging ───────────────────────────────────────────────────────────────

  @doc "Records a writer's message in the conversation."
  @spec post_user_message(Conversation.t(), String.t()) ::
          {:ok, ChatMessage.t()} | {:error, Ecto.Changeset.t()}
  def post_user_message(%Conversation{} = conversation, content) when is_binary(content) do
    %ChatMessage{}
    |> ChatMessage.create_changeset(%{
      role: :user,
      content: content,
      conversation_id: conversation.id
    })
    |> Repo.insert()
  end

  @doc """
  Generates and stores an assistant reply for the given conversation.

  Loads the full message history ordered by insertion time, passes it to the
  configured LLM adapter, then persists and returns the assistant's ChatMessage.
  """
  @spec answer(Conversation.t(), String.t()) :: {:ok, ChatMessage.t()} | {:error, term()}
  def answer(%Conversation{} = conversation, locale \\ "en") do
    history =
      from(m in ChatMessage,
        where: m.conversation_id == ^conversation.id,
        order_by: [asc: m.inserted_at, asc: m.id],
        select: %{role: m.role, content: m.content}
      )
      |> Repo.all()

    with {:ok, %{role: :assistant, content: content}} <- llm().complete(history, locale: locale) do
      %ChatMessage{}
      |> ChatMessage.create_changeset(%{
        role: :assistant,
        content: content,
        conversation_id: conversation.id
      })
      |> Repo.insert()
    end
  end

  # ── Reviews ───────────────────────────────────────────────────────────────

  @doc """
  Generates a manuscript review at the given processing level via the configured
  LLM adapter. `:full` runs the complete review; `:preview` runs a lighter free
  pass. The org + owner prompt layers are composed (with hardening) into the
  system prompt handed to the adapter. Returns `{:ok, %{overall_feedback,
  comments}}` with atom-keyed comment maps ready for `History` to persist.
  """
  @spec review_document(String.t(), PerfectPaper.Chatbot.LLM.level(), %{
          optional(:locale) => String.t(),
          org_id: binary() | nil,
          owner_type: :user | :group,
          owner_id: binary()
        }) ::
          {:ok, %{overall_feedback: String.t(), comments: [map()]}} | {:error, term()}
  def review_document(text, level, scope) when is_binary(text) and level in [:preview, :full] do
    org = scope[:org_id] && get_prompt_layer(:organization, scope.org_id)
    owner = get_prompt_layer(scope.owner_type, scope.owner_id)
    system = Prompt.compose(level, %{org: org, owner: owner})
    llm().review(text, system, level: level, locale: scope[:locale] || "en")
  end

  # ── Prompt layers ───────────────────────────────────────────────────────────

  @doc "Returns the editable prompt body for a scope, or nil."
  @spec get_prompt_layer(:organization | :group | :user, binary()) :: String.t() | nil
  def get_prompt_layer(scope, scope_id) do
    case Repo.get_by(PromptLayer, scope: scope, scope_id: scope_id) do
      nil -> nil
      layer -> layer.body
    end
  end

  @doc "Atomically upserts the prompt layer for a scope (ON CONFLICT on the unique (scope, scope_id))."
  @spec put_prompt_layer(:organization | :group | :user, binary(), String.t() | nil, binary()) ::
          {:ok, PromptLayer.t()} | {:error, Ecto.Changeset.t()}
  def put_prompt_layer(scope, scope_id, body, updated_by_id) do
    %PromptLayer{}
    |> PromptLayer.changeset(%{
      scope: scope,
      scope_id: scope_id,
      body: body,
      updated_by_id: updated_by_id
    })
    |> Repo.insert(
      on_conflict: {:replace, [:body, :updated_by_id, :updated_at]},
      conflict_target: [:scope, :scope_id],
      returning: true
    )
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp llm, do: Application.get_env(:perfect_paper, :llm_provider)
end
