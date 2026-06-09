defmodule PerfectPaper.Repo.Migrations.CreateOrgSsoConfigs do
  use Ecto.Migration

  def change do
    create table(:org_sso_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :protocol, :string, null: false
      add :email_domain, :string, null: false
      add :domain_verified, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: false
      # OIDC
      add :oidc_tenant_id, :string
      add :oidc_client_id, :string
      add :oidc_client_secret, :string
      # SAML
      add :saml_idp_entity_id, :string
      add :saml_idp_sso_url, :string
      add :saml_idp_cert, :text
      add :saml_sp_entity_id, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:org_sso_configs, [:organization_id])
    create unique_index(:org_sso_configs, [:email_domain])
  end
end
