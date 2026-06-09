defmodule PerfectPaper.Accounts.MFA.RecoveryCode do
  @moduledoc "A single-use MFA recovery code. Only the hash is stored — TODO(mfa): hashing on generation (SOC 2 CC6.1)."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "mfa_recovery_codes" do
    field :user_id, :binary_id
    field :code_hash, :string
    field :used_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a recovery code (stores hash only)."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(code, attrs) do
    code
    |> cast(attrs, [:user_id, :code_hash, :used_at])
    |> validate_required([:user_id, :code_hash])
  end
end
