defmodule PerfectPaper.AuthzFixtures do
  @moduledoc "Test fixtures for the Authz context."

  alias PerfectPaper.Authz.ResourceGrant
  alias PerfectPaper.Repo

  @doc "Grants `role` on a session to a user (subject_type :user)."
  def session_grant_fixture(session, user, role \\ :commenter) do
    {:ok, grant} =
      %ResourceGrant{}
      |> ResourceGrant.create_changeset(%{
        resource_type: :session,
        resource_id: session.id,
        subject_type: :user,
        subject_id: user.id,
        role: role,
        granted_by: user.id
      })
      |> Repo.insert()

    grant
  end
end
