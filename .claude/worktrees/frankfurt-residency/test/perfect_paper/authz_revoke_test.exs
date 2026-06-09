defmodule PerfectPaper.AuthzRevokeTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Authz
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  import PerfectPaper.HistoryFixtures
  import PerfectPaper.AuthzFixtures

  test "revoke_user_grants_in_org removes the user's grants on that org's sessions only" do
    owner = user_fixture()
    grantee = user_fixture()
    org = organization_fixture(owner)
    {:ok, group} = PerfectPaper.Organizations.create_group(org, %{name: "G"})
    session = session_fixture(%{group: group})
    _grant = session_grant_fixture(session, grantee, :commenter)

    # A grant on a different org's session must survive.
    other_owner = user_fixture()
    other_org = organization_fixture(other_owner)
    {:ok, other_group} = PerfectPaper.Organizations.create_group(other_org, %{name: "H"})
    other_session = session_fixture(%{group: other_group})
    _other_grant = session_grant_fixture(other_session, grantee, :commenter)

    assert 1 = Authz.revoke_user_grants_in_org(grantee.id, org.id)

    grants =
      PerfectPaper.Repo.all(
        from g in PerfectPaper.Authz.ResourceGrant, where: g.subject_id == ^grantee.id
      )

    assert [%{resource_id: rid}] = grants
    assert rid == other_session.id
  end
end
