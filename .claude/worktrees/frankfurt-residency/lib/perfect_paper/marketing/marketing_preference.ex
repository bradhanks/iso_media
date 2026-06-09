defmodule PerfectPaper.Marketing.MarketingPreference do
  @moduledoc """
  A user's marketing communication preferences. Tracks opt-in status for
  general marketing emails and product update notifications.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "marketing_preferences" do
    field :opt_in, :boolean, default: false
    field :product_updates, :boolean, default: false
    field :user_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc "Builds a changeset for creating or updating marketing preferences."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(preference, attrs) do
    preference
    |> cast(attrs, [:opt_in, :product_updates, :user_id])
    |> validate_required([:user_id])
    |> unique_constraint(:user_id)
  end
end
