defmodule PerfectPaper.Scim.Token do
  @moduledoc """
  A per-org SCIM bearer token. The plaintext is shown to the admin exactly once
  at generation; only its SHA-256 hash is persisted. Verification hashes the
  incoming token and constant-time-compares against the stored hash.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "scim_tokens" do
    field :organization_id, :binary_id
    field :token_hash, :string
    field :created_by, :binary_id
    field :last_used_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @prefix "scim_"

  @doc "Generates a random plaintext token (shown once)."
  @spec generate_plaintext() :: String.t()
  def generate_plaintext,
    do: @prefix <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))

  @doc "SHA-256 hex hash of a plaintext token — what we persist and compare."
  @spec hash(String.t()) :: String.t()
  def hash(plaintext) when is_binary(plaintext),
    do: :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)

  @doc "Changeset for a new token row (stores only the hash)."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(token, attrs) do
    token
    |> cast(attrs, [:organization_id, :token_hash, :created_by])
    |> validate_required([:organization_id, :token_hash])
    |> unique_constraint(:organization_id)
    |> unique_constraint(:token_hash)
  end
end
