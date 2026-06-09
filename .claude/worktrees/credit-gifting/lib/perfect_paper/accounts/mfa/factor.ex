defmodule PerfectPaper.Accounts.MFA.Factor do
  @moduledoc "An enrolled MFA factor (TOTP or WebAuthn). Adapter-owned `secret` is opaque to the context."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_mfa_factors" do
    field :user_id, :binary_id
    field :type, Ecto.Enum, values: [:totp, :webauthn]
    field :secret, :binary
    field :label, :string
    field :confirmed_at, :utc_datetime
    field :last_used_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for enrolling a factor. `secret` must be encrypted before this — TODO(mfa): app-level encryption (SOC 2 CC6.7)."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(factor, attrs) do
    factor
    |> cast(attrs, [:user_id, :type, :secret, :label, :confirmed_at, :last_used_at])
    |> validate_required([:user_id, :type])
    |> unique_constraint([:user_id, :type, :label])
  end
end
