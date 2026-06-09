defmodule PerfectPaper.SSO.SsoConfig do
  @moduledoc """
  Schema and credential changeset for per-organization enterprise SSO configuration.

  One config per org. `protocol` is `:oidc` or `:saml`; `email_domain` uniquely
  routes login to the correct IdP. The domain must be a private/corporate domain —
  public free-email domains (gmail.com, outlook.com, etc.) are rejected.

  `domain_verified` and `enabled` are intentionally excluded from `changeset/2`.
  They are toggled only via dedicated context functions in Task 4 to prevent
  accidental or unauthorized activation of unverified configs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: binary() | nil,
          organization_id: binary() | nil,
          protocol: :oidc | :saml | nil,
          email_domain: String.t() | nil,
          domain_verified: boolean(),
          enabled: boolean(),
          oidc_tenant_id: String.t() | nil,
          oidc_client_id: String.t() | nil,
          oidc_client_secret: String.t() | nil,
          saml_idp_entity_id: String.t() | nil,
          saml_idp_sso_url: String.t() | nil,
          saml_idp_cert: String.t() | nil,
          saml_sp_entity_id: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "org_sso_configs" do
    field :organization_id, :binary_id
    field :protocol, Ecto.Enum, values: [:oidc, :saml]
    field :email_domain, :string
    field :domain_verified, :boolean, default: false
    field :enabled, :boolean, default: false

    # OIDC credentials
    field :oidc_tenant_id, :string
    field :oidc_client_id, :string
    # TODO(sso): encrypt at rest (app-level, SOC 2 CC6.7 — shared with MFA/webhooks secrets)
    field :oidc_client_secret, :string

    # SAML credentials
    field :saml_idp_entity_id, :string
    field :saml_idp_sso_url, :string
    # TODO(sso): encrypt at rest (app-level, SOC 2 CC6.7 — shared with MFA/webhooks secrets)
    field :saml_idp_cert, :string
    field :saml_sp_entity_id, :string

    timestamps(type: :utc_datetime)
  end

  @public_domains ~w(
    gmail.com outlook.com hotmail.com yahoo.com
    icloud.com proton.me live.com aol.com
  )

  @credential_fields [
    :organization_id,
    :protocol,
    :email_domain,
    :oidc_tenant_id,
    :oidc_client_id,
    :oidc_client_secret,
    :saml_idp_entity_id,
    :saml_idp_sso_url,
    :saml_idp_cert,
    :saml_sp_entity_id
  ]

  @doc """
  Changeset for creating or updating SSO credential configuration.

  Does NOT accept `domain_verified` or `enabled` — those are flipped by
  dedicated context functions. Validates protocol-specific required fields
  and blocks public/free email domains.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(sso_config, attrs) do
    sso_config
    |> cast(attrs, @credential_fields)
    |> update_change(:email_domain, &sanitize_domain/1)
    |> validate_required([:organization_id, :protocol, :email_domain])
    |> validate_exclusion(:email_domain, @public_domains,
      message: "must be a private corporate domain, not a public email provider"
    )
    |> validate_protocol_fields()
    |> unique_constraint(:organization_id,
      message: "already has an SSO configuration"
    )
    |> unique_constraint(:email_domain,
      message: "is already claimed by another organization"
    )
  end

  @doc false
  @spec sanitize_domain(String.t()) :: String.t()
  @spec sanitize_domain(term()) :: term()
  def sanitize_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.downcase()
    |> String.replace_leading("@", "")
    |> String.trim_trailing("/")
    |> String.trim()
  end

  def sanitize_domain(other), do: other

  # Applies protocol-specific required field validation based on the cast value
  # of :protocol. Runs after cast so the protocol value is already normalized.
  defp validate_protocol_fields(changeset) do
    case get_field(changeset, :protocol) do
      :oidc ->
        validate_required(changeset, [:oidc_tenant_id, :oidc_client_id, :oidc_client_secret],
          message: "can't be blank"
        )

      :saml ->
        validate_required(changeset, [:saml_idp_entity_id, :saml_idp_sso_url, :saml_idp_cert],
          message: "can't be blank"
        )

      _ ->
        changeset
    end
  end
end
