defmodule PerfectPaper.Compliance.DsarRequest do
  @moduledoc """
  Embedded schema for a Data Subject Access / rights Request (DSAR).

  Validated by `Compliance.submit_dsar/1`; never persisted to the database —
  the submitted form is delivered to the privacy team via email.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @request_types [
    :access,
    :correction,
    :erasure,
    :portability,
    :object_to_processing,
    :restrict_processing,
    :withdraw_consent
  ]

  embedded_schema do
    field :name, :string
    field :email, :string
    field :request_type, Ecto.Enum, values: @request_types
    field :message, :string
  end

  @doc "Human-readable label for a request type atom."
  @spec request_type_label(atom()) :: String.t()
  def request_type_label(:access), do: "Access — a copy of the personal data held about me"
  def request_type_label(:correction), do: "Correction — correct inaccurate data"
  def request_type_label(:erasure), do: "Erasure — delete all my personal data"

  def request_type_label(:portability),
    do: "Portability — export my data in a machine-readable format"

  def request_type_label(:object_to_processing),
    do: "Object — stop processing my data for a purpose"

  def request_type_label(:restrict_processing),
    do: "Restrict — limit how my data is processed"

  def request_type_label(:withdraw_consent),
    do: "Withdraw consent — revoke a consent I gave"

  @doc "Returns all request types as `{label, value}` tuples for a select input."
  @spec request_type_options() :: [{String.t(), atom()}]
  def request_type_options, do: Enum.map(@request_types, &{request_type_label(&1), &1})

  @doc "Validates a DSAR request."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = dsar, attrs) do
    dsar
    |> cast(attrs, [:name, :email, :request_type, :message])
    |> validate_required([:name, :email, :request_type])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:message, max: 2000)
  end
end
