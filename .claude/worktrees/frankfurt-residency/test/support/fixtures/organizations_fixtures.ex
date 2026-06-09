defmodule PerfectPaper.OrganizationsFixtures do
  @moduledoc "Test fixtures for the Organizations context."

  alias PerfectPaper.Organizations

  @doc "Creates an organization owned by the given user, with default credit_pool of 100."
  def organization_fixture(owner, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:name, "Test Org #{System.unique_integer()}")
      |> Map.put_new(:credit_pool, 100)

    {:ok, org} = Organizations.create_organization(owner, attrs)
    org
  end

  @doc "Creates a membership for the given user in the given organization."
  def membership_fixture(org, user, role \\ :member) do
    {:ok, membership} = Organizations.add_member(org, user, role)
    membership
  end

  @doc "Creates a group in the org. Pass `parent: %Group{}` for a child node."
  def group_fixture(org, attrs \\ %{}) do
    attrs = Map.new(attrs)
    parent = attrs[:parent]

    {:ok, group} =
      PerfectPaper.Organizations.create_group(org, %{
        name: attrs[:name] || "Group #{System.unique_integer([:positive])}",
        kind: attrs[:kind] || :group,
        parent_id: parent && parent.id
      })

    group
  end

  @doc "Adds a user to a group with the given role (default :viewer)."
  def group_membership_fixture(group, user, role \\ :viewer) do
    {:ok, m} = PerfectPaper.Organizations.add_group_member(group, user, role)
    m
  end
end
