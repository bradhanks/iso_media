defmodule PerfectPaper.Audit.GroupTenancyTest do
  @moduledoc "Audit fix: set_group_members must only admit ACTIVE members of the group's own org (no cross-org injection)."
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Organizations
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  test "a foreign-org user is NOT injected into a group; only same-org active members are added" do
    owner_a = user_fixture()
    org_a = organization_fixture(owner_a)
    member_a = user_fixture()
    {:ok, _} = Organizations.add_member(org_a, member_a, :member)

    # user_b belongs ONLY to org_b.
    org_b = organization_fixture(user_fixture())
    user_b = user_fixture()
    {:ok, _} = Organizations.add_member(org_b, user_b, :member)

    {:ok, group} = Organizations.create_group(org_a, %{name: "Eng"})

    # Try to set both — the foreign user_b must be dropped.
    :ok = Organizations.set_group_members(group, [member_a.id, user_b.id])

    paths = Organizations.authorized_group_paths(member_a.id)
    assert paths == [group.path]
    assert Organizations.authorized_group_paths(user_b.id) == []
  end

  test "a deactivated same-org member is not (re)admitted" do
    owner = user_fixture()
    org = organization_fixture(owner)
    member = user_fixture()
    {:ok, _} = Organizations.add_member(org, member, :member)
    {:ok, _} = Organizations.deactivate_membership(org, member.id)

    {:ok, group} = Organizations.create_group(org, %{name: "G"})
    :ok = Organizations.set_group_members(group, [member.id])

    assert Organizations.authorized_group_paths(member.id) == []
  end
end
