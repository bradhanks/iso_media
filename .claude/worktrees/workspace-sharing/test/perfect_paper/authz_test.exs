defmodule PerfectPaper.AuthzTest do
  use PerfectPaper.DataCase, async: true

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  alias PerfectPaper.Authz
  alias PerfectPaper.Organizations

  describe "load_subject/1" do
    test "carries the user and the ltree paths of its group memberships" do
      user = user_fixture()
      org = organization_fixture(user)
      {:ok, college} = PerfectPaper.Organizations.create_group(org, %{name: "College"})
      group_membership_fixture(college, user, :admin)

      scope = Authz.load_subject(user)

      assert scope.user.id == user.id
      assert scope.group_paths == [college.path]
    end

    test "group_paths is empty for a user with no memberships" do
      scope = Authz.load_subject(user_fixture())
      assert scope.group_paths == []
    end
  end

  describe "permit?/4" do
    import PerfectPaper.HistoryFixtures
    import PerfectPaper.AuthzFixtures

    test "user owner may read and edit their own session" do
      user = user_fixture()
      session = session_fixture(user: user) |> Repo.reload()
      scope = Authz.load_subject(user)

      assert Authz.permit?(scope, :read, session) == :ok
      assert Authz.permit?(scope, :edit, session) == :ok
    end

    test "unrelated user gets :not_found (no line of sight)" do
      session = session_fixture() |> Repo.reload()
      scope = Authz.load_subject(user_fixture())

      assert Authz.permit?(scope, :read, session) == {:error, :not_found}
    end

    test "ancestor-group role covers a descendant-group-owned session" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      {:ok, college} = Organizations.create_group(org, %{name: "College"})
      {:ok, dept} = Organizations.create_group(org, %{name: "Dept", parent_id: college.id})
      group_membership_fixture(college, member, :editor)

      session = session_fixture(group: dept) |> Repo.reload()
      scope = Authz.load_subject(member)

      assert Authz.permit?(scope, :read, session) == :ok
      assert Authz.permit?(scope, :edit, session) == :ok
      assert Authz.permit?(scope, :delete, session) == {:error, :unauthorized}
    end

    test "sibling-group role does NOT reach another subtree" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      {:ok, college} = Organizations.create_group(org, %{name: "College"})
      {:ok, eng} = Organizations.create_group(org, %{name: "Eng", parent_id: college.id})
      {:ok, arts} = Organizations.create_group(org, %{name: "Arts", parent_id: college.id})
      group_membership_fixture(eng, member, :admin)

      session = session_fixture(group: arts) |> Repo.reload()
      scope = Authz.load_subject(member)

      assert Authz.permit?(scope, :read, session) == {:error, :not_found}
    end

    test "a resource grant gives a visible-but-limited role" do
      owner = user_fixture()
      guest = user_fixture()
      session = session_fixture(user: owner) |> Repo.reload()
      session_grant_fixture(session, guest, :commenter)
      scope = Authz.load_subject(guest)

      assert Authz.permit?(scope, :comment, session) == :ok
      assert Authz.permit?(scope, :edit, session) == {:error, :unauthorized}
    end

    test "mutating decisions are logged; reads are not" do
      user = user_fixture()
      session = session_fixture(user: user) |> Repo.reload()
      scope = Authz.load_subject(user)

      Authz.permit?(scope, :read, session)
      assert Repo.aggregate(PerfectPaper.Authz.Decision, :count) == 0

      Authz.permit?(scope, :edit, session)
      assert Repo.aggregate(PerfectPaper.Authz.Decision, :count) == 1
    end
  end

  describe "scope_query/3" do
    import PerfectPaper.HistoryFixtures
    alias PerfectPaper.History.Session

    test "returns only sessions the subject owns or inherits via a group" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      {:ok, college} = Organizations.create_group(org, %{name: "College"})
      {:ok, dept} = Organizations.create_group(org, %{name: "Dept", parent_id: college.id})
      group_membership_fixture(college, member, :viewer)

      mine = session_fixture(user: member)
      dept_doc = session_fixture(group: dept)
      _someone_elses = session_fixture()

      scope = Authz.load_subject(member)

      ids =
        Session
        |> Authz.scope_query(scope, :read)
        |> Repo.all()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert Enum.sort([mine.id, dept_doc.id]) == ids
    end
  end

  describe "permit?/4 nil-user guard" do
    import PerfectPaper.HistoryFixtures

    test "a scope with no user gets :not_found (never crashes)" do
      session = session_fixture() |> Repo.reload()

      assert Authz.permit?(%PerfectPaper.Accounts.Scope{user: nil}, :read, session) ==
               {:error, :not_found}
    end
  end

  describe "permit?/4 unknown resource type" do
    test "returns {:error, :unauthorized} for an unknown resource type instead of crashing" do
      scope = %PerfectPaper.Accounts.Scope{user: user_fixture()}

      assert {:error, :unauthorized} =
               PerfectPaper.Authz.permit?(scope, :read, %{some: :random_struct})
    end
  end

  describe "grant write API" do
    import PerfectPaper.HistoryFixtures
    import PerfectPaper.AuthzFixtures

    alias PerfectPaper.Authz.ResourceGrant

    setup do
      owner = user_fixture()
      guest = user_fixture()
      session = session_fixture(user: owner) |> Repo.reload()
      owner_scope = Authz.load_subject(owner)
      guest_scope = Authz.load_subject(guest)

      %{
        owner: owner,
        guest: guest,
        session: session,
        owner_scope: owner_scope,
        guest_scope: guest_scope
      }
    end

    test "grant_access returns {:ok, grant} with the given role", %{
      owner_scope: owner_scope,
      session: session,
      guest: guest
    } do
      assert {:ok, grant} =
               Authz.grant_access(
                 owner_scope,
                 {:session, session.id},
                 {:user, guest.id},
                 :commenter
               )

      assert grant.role == :commenter
      assert grant.resource_type == :session
      assert grant.resource_id == session.id
      assert grant.subject_type == :user
      assert grant.subject_id == guest.id
    end

    test "re-granting with a different role upserts (ONE row, updated role)", %{
      owner_scope: owner_scope,
      session: session,
      guest: guest
    } do
      {:ok, _} =
        Authz.grant_access(owner_scope, {:session, session.id}, {:user, guest.id}, :commenter)

      {:ok, updated} =
        Authz.grant_access(owner_scope, {:session, session.id}, {:user, guest.id}, :editor)

      assert updated.role == :editor

      count =
        Repo.aggregate(
          from(g in ResourceGrant,
            where:
              g.resource_type == :session and g.resource_id == ^session.id and
                g.subject_type == :user and g.subject_id == ^guest.id
          ),
          :count
        )

      assert count == 1
    end

    test "non-owner/non-admin scope cannot grant", %{guest_scope: guest_scope, session: session} do
      other = user_fixture()

      assert Authz.grant_access(
               guest_scope,
               {:session, session.id},
               {:user, other.id},
               :commenter
             ) ==
               {:error, :not_found}
    end

    test "a commenter-role scope (limited grant) cannot grant", %{
      owner_scope: owner_scope,
      session: session,
      guest: guest
    } do
      {:ok, _} =
        Authz.grant_access(owner_scope, {:session, session.id}, {:user, guest.id}, :commenter)

      commenter_scope = Authz.load_subject(guest)
      third = user_fixture()

      assert Authz.grant_access(
               commenter_scope,
               {:session, session.id},
               {:user, third.id},
               :commenter
             ) ==
               {:error, :unauthorized}
    end

    test "revoke_access removes the grant and returns :ok", %{
      owner_scope: owner_scope,
      session: session,
      guest: guest
    } do
      {:ok, _} =
        Authz.grant_access(owner_scope, {:session, session.id}, {:user, guest.id}, :commenter)

      assert :ok = Authz.revoke_access(owner_scope, {:session, session.id}, {:user, guest.id})

      count =
        Repo.aggregate(
          from(g in ResourceGrant,
            where:
              g.resource_type == :session and g.resource_id == ^session.id and
                g.subject_type == :user and g.subject_id == ^guest.id
          ),
          :count
        )

      assert count == 0
    end

    test "revoking a non-existent grant returns {:error, :not_found}", %{
      owner_scope: owner_scope,
      session: session,
      guest: guest
    } do
      assert Authz.revoke_access(owner_scope, {:session, session.id}, {:user, guest.id}) ==
               {:error, :not_found}
    end

    test "non-admin scope cannot revoke", %{guest_scope: guest_scope, session: session} do
      other = user_fixture()

      assert Authz.revoke_access(guest_scope, {:session, session.id}, {:user, other.id}) ==
               {:error, :not_found}
    end

    test "list_grants returns {:ok, grants} for an owner", %{
      owner_scope: owner_scope,
      session: session,
      guest: guest
    } do
      {:ok, _} =
        Authz.grant_access(owner_scope, {:session, session.id}, {:user, guest.id}, :commenter)

      assert {:ok, grants} = Authz.list_grants(owner_scope, {:session, session.id})
      assert length(grants) == 1
      assert hd(grants).subject_id == guest.id
    end

    test "non-admin scope cannot list grants", %{guest_scope: guest_scope, session: session} do
      assert Authz.list_grants(guest_scope, {:session, session.id}) == {:error, :not_found}
    end
  end
end
