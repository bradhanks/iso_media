defmodule PerfectPaper.Repo.Migrations.AddScimFieldsToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :scim_managed, :boolean, null: false, default: false
      add :scim_external_id, :string
    end

    create unique_index(:groups, [:organization_id, :scim_external_id],
             where: "scim_external_id IS NOT NULL",
             name: :groups_org_scim_external_id_index
           )
  end
end
