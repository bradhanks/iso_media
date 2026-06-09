defmodule PerfectPaper.OrganizationsLifecycleTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Organizations
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    owner = user_fixture()
    member = user_fixture()
    org = organization_fixture(owner)
    {:ok, _} = Organizations.add_member(org, member, :member)
    %{org: org, owner: owner, member: member}
  end

  test "deactivate_membership marks deactivated + strips group memberships", %{
    org: org,
    member: member
  } do
    {:ok, group} = Organizations.create_group(org, %{name: "G"})
    {:ok, _} = Organizations.add_group_member(group, member, :viewer)

    assert {:ok, m} = Organizations.deactivate_membership(org, member.id)
    assert m.status == :deactivated
    assert m.deactivated_at
    assert Organizations.authorized_group_paths(member.id) == []
  end

  test "reactivate_membership restores active status", %{org: org, member: member} do
    {:ok, _} = Organizations.deactivate_membership(org, member.id)
    assert {:ok, m} = Organizations.reactivate_membership(org, member.id)
    assert m.status == :active
    refute m.deactivated_at
  end

  test "deactivating the org owner is refused", %{org: org, owner: owner} do
    assert {:error, :sole_owner} = Organizations.deactivate_membership(org, owner.id)
  end

  test "deactivating a non-member returns :not_found", %{org: org} do
    assert {:error, :not_found} = Organizations.deactivate_membership(org, Ecto.UUID.generate())
  end

  test "set_group_members is idempotent (re-adding is a no-op success)", %{
    org: org,
    member: member
  } do
    {:ok, group} = Organizations.create_group(org, %{name: "G"})
    assert :ok = Organizations.set_group_members(group, [member.id])
    assert :ok = Organizations.set_group_members(group, [member.id])
    assert Organizations.authorized_group_paths(member.id) == [group.path]
  end

  test "set_group_members removes absent members", %{org: org, member: member} do
    other = user_fixture()
    {:ok, _} = Organizations.add_member(org, other, :member)
    {:ok, group} = Organizations.create_group(org, %{name: "G"})
    :ok = Organizations.set_group_members(group, [member.id, other.id])
    :ok = Organizations.set_group_members(group, [other.id])
    assert Organizations.authorized_group_paths(member.id) == []
  end

  test "has_other_active_membership? sees memberships in OTHER orgs only", %{
    org: org,
    member: member
  } do
    # Excluding their only org → no other active membership.
    refute Organizations.has_other_active_membership?(member.id, org.id)

    other_owner = user_fixture()
    other_org = organization_fixture(other_owner)
    {:ok, _} = Organizations.add_member(other_org, member, :member)

    # Now, excluding `org`, they still have an active membership in other_org.
    assert Organizations.has_other_active_membership?(member.id, org.id)
  end
end
