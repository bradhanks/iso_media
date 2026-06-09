defmodule PerfectPaper.ApiKeys.ApiKey do
  @moduledoc """
  A user's API key. Only the SHA-256 hash of the token is stored; the raw token
  is shown once at creation and never persisted.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_keys" do
    field :name, :string
    field :prefix, :string
    field :token_hash, :binary
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Builds a changeset for issuing a new key."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :prefix, :token_hash, :user_id])
    |> validate_required([:prefix, :token_hash, :user_id])
    |> unique_constraint(:token_hash)
  end
end
