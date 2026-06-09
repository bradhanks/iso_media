defmodule PerfectPaper.Accounts.UserIdentity do
  @moduledoc """
  A link between a `User` and an external identity provider (Google, GitHub,
  etc.). A user may have many identities; each `(provider, provider_uid)` pair
  is globally unique.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  # Social OAuth providers, in display order.
  @oauth_providers ~w(google microsoft orcid github apple)

  # SSO identity providers use a scoped prefix ("oidc:{org_id}", "saml:{org_id}",
  # or "stub" for tests). This pattern accepts those prefixes.
  @sso_provider_prefixes ~w(oidc: saml: scim: stub)

  schema "user_identities" do
    field :provider, :string
    field :provider_uid, :string
    field :provider_email, :string

    belongs_to :user, PerfectPaper.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Known social OAuth provider keys, in display order."
  @spec providers() :: [String.t()]
  def providers, do: @oauth_providers

  @doc "Validates an identity link before insert."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:user_id, :provider, :provider_uid, :provider_email])
    |> validate_required([:user_id, :provider, :provider_uid])
    |> validate_provider()
    |> unique_constraint([:provider, :provider_uid],
      name: :user_identities_provider_provider_uid_index
    )
  end

  # Accepts social OAuth providers AND enterprise SSO provider strings
  # (prefixed with "oidc:", "saml:", or the literal "stub" for tests).
  @spec validate_provider(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_provider(changeset) do
    validate_change(changeset, :provider, fn :provider, value ->
      if valid_provider?(value),
        do: [],
        else: [provider: "is invalid"]
    end)
  end

  defp valid_provider?(value) when is_binary(value) do
    value in @oauth_providers or
      Enum.any?(@sso_provider_prefixes, &String.starts_with?(value, &1))
  end

  defp valid_provider?(_), do: false
end
