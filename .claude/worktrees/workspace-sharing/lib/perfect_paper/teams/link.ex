defmodule PerfectPaper.Teams.Link do
  @moduledoc """
  Links a PerfectPaper user to their Microsoft Teams identity (Entra AAD object
  id + tenant) and stores the Bot Framework `conversation_reference` used to send
  proactive messages. One link per user and per AAD object id.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "teams_links" do
    field :user_id, :binary_id
    field :aad_object_id, :string
    field :tenant_id, :string
    field :service_url, :string
    field :conversation_reference, :map, default: %{}
    field :muted, :boolean, default: false
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating/upserting a Teams link."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :user_id,
      :aad_object_id,
      :tenant_id,
      :service_url,
      :conversation_reference,
      :muted
    ])
    |> validate_required([:user_id, :aad_object_id, :tenant_id])
    |> unique_constraint(:user_id)
    |> unique_constraint(:aad_object_id)
  end

  @doc "Changeset toggling the mute flag."
  @spec mute_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def mute_changeset(link, muted), do: change(link, muted: muted)
end
