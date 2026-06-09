defmodule PerfectPaper.Chatbot.PromptLayer do
  @moduledoc """
  One editable prompt layer for a scope (organization / group / user). Composed
  into the review system prompt at call time. Blank body = the layer is "off".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @scopes [:organization, :group, :user]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "prompt_layers" do
    field :scope, Ecto.Enum, values: @scopes
    field :scope_id, :binary_id
    field :body, :string
    field :updated_by_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Validates/normalizes a prompt layer. Whitespace-only body → nil; body capped at 4000 chars."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(layer, attrs) do
    layer
    |> cast(attrs, [:scope, :scope_id, :body, :updated_by_id])
    |> update_change(:body, &trim_and_nilify/1)
    |> validate_required([:scope, :scope_id])
    |> validate_length(:body, max: 4000)
    |> unique_constraint([:scope, :scope_id])
  end

  defp trim_and_nilify(nil), do: nil

  defp trim_and_nilify(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
