defmodule PerfectPaper.OrganizationsTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Organizations

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  describe "create_organization/2" do
    test "creates an organization with valid attrs" do
      owner = user_fixture()
      assert {:ok, org} = Organizations.create_organization(owner, %{name: "Scholars United"})
      assert org.name == "Scholars United"
      assert org.owner_id == owner.id
      assert org.credit_pool == 0
    end

    test "sets credit_pool when provided" do
      owner = user_fixture()

      assert {:ok, org} =
               Organizations.create_organization(owner, %{name: "Funded Lab", credit_pool: 500})

      assert org.credit_pool == 500
    end

    test "requires a name" do
      owner = user_fixture()
      assert {:error, changeset} = Organizations.create_organization(owner, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "add_member/3" do
    test "adds a user to an organization with default role :member" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)

      assert {:ok, membership} = Organizations.add_member(org, member)
      assert membership.organization_id == org.id
      assert membership.user_id == member.id
      assert membership.role == :member
      assert membership.allocated_credits == 0
    end

    test "adds a user with a specified role" do
      owner = user_fixture()
      admin = user_fixture()
      org = organization_fixture(owner)

      assert {:ok, membership} = Organizations.add_member(org, admin, :admin)
      assert membership.role == :admin
    end

    test "prevents duplicate memberships for the same org and user" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)

      assert {:ok, _} = Organizations.add_member(org, member)
      assert {:error, changeset} = Organizations.add_member(org, member)
      assert changeset.errors[:organization_id] != nil or changeset.errors[:user_id] != nil
    end
  end

  describe "credit_pool_status/1" do
    test "returns correct pool, allocated, and available when no members have credits" do
      owner = user_fixture()
      org = organization_fixture(owner, %{credit_pool: 100})

      status = Organizations.credit_pool_status(org.id)

      assert status.pool == 100
      assert status.allocated == 0
      assert status.available == 100
    end

    test "returns correct pool, allocated, and available after allocations" do
      owner = user_fixture()
      member1 = user_fixture()
      member2 = user_fixture()
      org = organization_fixture(owner, %{credit_pool: 200})
      membership_fixture(org, member1)
      membership_fixture(org, member2)

      {:ok, _} = Organizations.allocate_credits_to_member(org.id, member1.id, 50)
      {:ok, _} = Organizations.allocate_credits_to_member(org.id, member2.id, 30)

      status = Organizations.credit_pool_status(org.id)

      assert status.pool == 120
      assert status.allocated == 80
      assert status.available == 40
    end
  end

  describe "allocate_credits_to_member/3" do
    test "decrements org pool and increments member allocated_credits" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner, %{credit_pool: 100})
      membership_fixture(org, member)

      assert {:ok, membership} = Organizations.allocate_credits_to_member(org.id, member.id, 40)
      assert membership.allocated_credits == 40

      status = Organizations.credit_pool_status(org.id)
      assert status.pool == 60
      assert status.allocated == 40
      assert status.available == 20
    end

    test "returns {:error, :insufficient_pool} when amount exceeds available credits" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner, %{credit_pool: 10})
      membership_fixture(org, member)

      assert {:error, :insufficient_pool} =
               Organizations.allocate_credits_to_member(org.id, member.id, 50)
    end

    test "returns {:error, :insufficient_pool} when pool is exactly exhausted" do
      owner = user_fixture()
      member1 = user_fixture()
      member2 = user_fixture()
      org = organization_fixture(owner, %{credit_pool: 100})
      membership_fixture(org, member1)
      membership_fixture(org, member2)

      {:ok, _} = Organizations.allocate_credits_to_member(org.id, member1.id, 100)

      assert {:error, :insufficient_pool} =
               Organizations.allocate_credits_to_member(org.id, member2.id, 1)
    end
  end

  describe "return_credits_to_pool/3" do
    test "increments org pool and decrements member allocated_credits" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner, %{credit_pool: 100})
      membership_fixture(org, member)

      {:ok, _allocated} = Organizations.allocate_credits_to_member(org.id, member.id, 60)
      assert {:ok, membership} = Organizations.return_credits_to_pool(org.id, member.id, 60)
      assert membership.allocated_credits == 0

      status = Organizations.credit_pool_status(org.id)
      assert status.pool == 100
      assert status.available == 100
    end

    test "clamps returned amount to the member's actual allocation (no negative allocated_credits)" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner, %{credit_pool: 100})
      membership_fixture(org, member)

      {:ok, _} = Organizations.allocate_credits_to_member(org.id, member.id, 20)

      # Attempt to return more than was allocated
      assert {:ok, membership} = Organizations.return_credits_to_pool(org.id, member.id, 999)
      assert membership.allocated_credits == 0

      status = Organizations.credit_pool_status(org.id)
      # Only 20 credits were returned (what was allocated)
      assert status.pool == 100
    end
  end

  describe "request_credits/3 (authorization guard)" do
    setup do
      owner = user_fixture()
      admin = user_fixture()
      plain_member = user_fixture()
      {:ok, org} = Organizations.create_organization(owner, %{name: "Acme", credit_pool: 200})
      {:ok, admin_membership} = Organizations.add_member(org, admin, :admin)
      {:ok, _} = Organizations.add_member(org, plain_member, :member)
      %{org: org, admin: admin, admin_membership: admin_membership, plain_member: plain_member}
    end

    test "an org admin can allocate credits to themselves", ctx do
      assert {:ok, _} = Organizations.request_credits(ctx.org.id, ctx.admin.id, 50)
    end

    test "a regular member cannot self-approve a credit request — pool drain prevented", ctx do
      assert {:error, :unauthorized} =
               Organizations.request_credits(ctx.org.id, ctx.plain_member.id, 50)
    end
  end

  describe "create_group/2" do
    test "top-level group path is the hyphen-stripped id" do
      owner = user_fixture()
      org = organization_fixture(owner)
      {:ok, group} = Organizations.create_group(org, %{name: "College of Arts"})

      assert group.path == String.replace(group.id, "-", "")
      assert group.parent_id == nil
    end

    test "child group path appends its label under the parent path" do
      owner = user_fixture()
      org = organization_fixture(owner)
      {:ok, parent} = Organizations.create_group(org, %{name: "College"})
      {:ok, child} = Organizations.create_group(org, %{name: "Dept", parent_id: parent.id})

      assert child.path == parent.path <> "." <> String.replace(child.id, "-", "")
    end
  end

  describe "authorized_group_paths/1" do
    test "returns ltree paths of every group the user holds a role at" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      {:ok, college} = Organizations.create_group(org, %{name: "College"})
      {:ok, _dept} = Organizations.create_group(org, %{name: "Dept", parent_id: college.id})

      group_membership_fixture(college, member, :admin)

      assert Organizations.authorized_group_paths(member.id) == [college.path]
    end

    test "returns [] for a user with no group memberships" do
      assert Organizations.authorized_group_paths(Ecto.UUID.generate()) == []
    end
  end

  describe "mfa_required_for_user?/1" do
    test "returns true when a member of an org with mfa_required == true" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner, %{mfa_required: true})
      membership_fixture(org, member, :member)

      assert Organizations.mfa_required_for_user?(member.id)
    end

    test "returns false when member of an org with mfa_required == false" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner, %{mfa_required: false})
      membership_fixture(org, member, :member)

      refute Organizations.mfa_required_for_user?(member.id)
    end

    test "returns false for an unknown user id" do
      refute Organizations.mfa_required_for_user?(Ecto.UUID.generate())
    end
  end

  describe "set_mfa_required/3" do
    import PerfectPaper.AccountsFixtures
    import PerfectPaper.OrganizationsFixtures

    test "the org owner can require MFA" do
      owner = user_fixture()
      org = organization_fixture(owner)
      scope = PerfectPaper.Authz.load_subject(owner)
      assert {:ok, updated} = PerfectPaper.Organizations.set_mfa_required(org, scope, true)
      assert updated.mfa_required
    end

    test "an org admin (membership role) can require MFA" do
      owner = user_fixture()
      admin = user_fixture()
      org = organization_fixture(owner)
      membership_fixture(org, admin, :admin)
      scope = PerfectPaper.Authz.load_subject(admin)
      assert {:ok, updated} = PerfectPaper.Organizations.set_mfa_required(org, scope, true)
      assert updated.mfa_required
    end

    test "a plain member cannot require MFA" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      membership_fixture(org, member, :member)
      scope = PerfectPaper.Authz.load_subject(member)

      assert PerfectPaper.Organizations.set_mfa_required(org, scope, true) ==
               {:error, :unauthorized}
    end

    test "an unrelated user cannot require MFA" do
      owner = user_fixture()
      org = organization_fixture(owner)
      scope = PerfectPaper.Authz.load_subject(user_fixture())

      assert PerfectPaper.Organizations.set_mfa_required(org, scope, true) ==
               {:error, :unauthorized}
    end
  end
end
