defmodule PerfectPaper.Compliance.CookieConsent do
  @moduledoc """
  A visitor's cookie-consent decision.

  This is a pure, schemaless value — it never touches the database. The decision
  is persisted in a signed first-party cookie, not a table. `essential` cookies
  are always on (they are strictly necessary to run PerfectPaper and need no
  consent); the remaining categories are opt-in and default to denied.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          essential: boolean(),
          analytics: boolean(),
          marketing: boolean(),
          version: integer() | nil,
          region: String.t() | nil,
          decided_at: DateTime.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :essential, :boolean, default: true
    field :analytics, :boolean, default: false
    field :marketing, :boolean, default: false
    field :version, :integer
    field :region, :string
    field :decided_at, :utc_datetime
  end

  @doc """
  Validates a consent decision. `essential` is always forced on regardless of
  input — strictly-necessary cookies cannot be refused.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(consent, attrs) do
    consent
    |> cast(attrs, [:analytics, :marketing, :version, :region, :decided_at])
    |> put_change(:essential, true)
    |> validate_required([:version, :decided_at])
  end
end
