defmodule PerfectPaper.Authz do
  @moduledoc """
  The single authorization boundary: the only place a "may this subject do this
  to this resource?" question is answered (`permit?/3,4`) and the only place a
  list query is narrowed to what a subject may see (`scope_query/3`).

  Rules are pure Elixir pattern-matching over a fixed role ladder; the 4-arity
  `permit?/4` signature is ABAC-shaped (subject + action + resource + env) so new
  attribute rules can be added as clauses without changing any call site.
  """
  import Ecto.Query

  alias PerfectPaper.{Repo, Organizations}
  alias PerfectPaper.Accounts.{Scope, User}
  alias PerfectPaper.Authz.{Role, Decision, ResourceGrant}
  alias PerfectPaper.History.Session

  @doc """
  Builds an enriched `Scope` for `user`, resolving the ltree paths of every group
  the user holds a role at (used by `scope_query/3` and `permit?/4`).
  """
  @spec load_subject(User.t()) :: Scope.t()
  def load_subject(user) do
    %Scope{user: user, group_paths: Organizations.authorized_group_paths(user.id)}
  end

  @type action :: Role.action()
  @type decision :: :ok | {:error, :unauthorized} | {:error, :not_found}

  @doc """
  Whether `scope` may perform `action` on `resource`.

  Returns `:ok`; `{:error, :not_found}` when the subject has no line of sight at
  all (hide existence); `{:error, :unauthorized}` when the resource is visible
  but the subject's role is below the action's requirement. Mutating actions are
  recorded in `authz_decisions` (best-effort).
  """
  @spec permit?(Scope.t(), action(), Session.t(), map()) :: decision()
  def permit?(scope, action, resource, env \\ %{})

  def permit?(%Scope{user: nil}, _action, _resource, _env), do: {:error, :not_found}

  def permit?(%Scope{} = scope, action, %Session{} = session, _env) do
    {role, reason} = effective_role(scope, session)

    decision =
      cond do
        is_nil(role) -> {:error, :not_found}
        Role.clears?(role, Role.required_for(action)) -> :ok
        true -> {:error, :unauthorized}
      end

    maybe_log(action, session, scope, decision, reason)
    decision
  end

  # Catch-all: any resource type not explicitly handled is denied, not raised.
  def permit?(%Scope{}, _action, _resource, _env), do: {:error, :unauthorized}

  @doc """
  Narrows a `Session` query to what `scope` may `:read`: sessions it owns
  directly, sessions owned by a group the subject inherits a role at
  (ltree descendant-or-equal of one of the subject's `group_paths`), or
  sessions for which the subject holds an explicit `ResourceGrant`.
  """
  @spec scope_query(Ecto.Queryable.t(), Scope.t(), :read) :: Ecto.Query.t()
  def scope_query(query, %Scope{user: %{id: uid}, group_paths: paths}, :read) do
    from s in query,
      left_join: g in ResourceGrant,
      on:
        g.resource_type == :session and g.resource_id == s.id and
          g.subject_type == :user and g.subject_id == ^uid,
      where:
        (s.owner_type == :user and s.owner_id == ^uid) or
          (s.owner_type == :group and not is_nil(s.owner_path) and
             fragment("?::ltree <@ ANY(?::ltree[])", s.owner_path, ^paths)) or
          not is_nil(g.id),
      distinct: true
  end

  # Highest role the scope holds on the session, plus a reason tag, or {nil, nil}.
  defp effective_role(%Scope{user: %{id: uid}}, %Session{} = session) do
    [
      owner_role(uid, session),
      group_role(uid, session),
      grant_role(uid, session)
    ]
    |> Enum.reject(&is_nil(elem(&1, 0)))
    |> case do
      [] -> {nil, nil}
      candidates -> Enum.max_by(candidates, fn {role, _} -> Role.rank(role) end)
    end
  end

  defp owner_role(uid, %Session{owner_type: :user, owner_id: uid}), do: {:owner, "owner"}
  defp owner_role(_uid, _session), do: {nil, nil}

  defp group_role(uid, %Session{owner_type: :group, owner_path: path}) when is_binary(path) do
    case highest_membership_role(uid, path) do
      nil -> {nil, nil}
      role -> {role, "group_inheritance"}
    end
  end

  defp group_role(_uid, _session), do: {nil, nil}

  # The strongest role among all ancestor-or-equal groups the user belongs to,
  # or nil when the user has no membership covering this path. Inheritance is UP
  # the tree: membership group path is an ancestor (@>) of the session owner_path.
  defp highest_membership_role(uid, path) do
    Repo.all(
      from m in Organizations.GroupMembership,
        join: g in Organizations.Group,
        on: g.id == m.group_id,
        where: m.user_id == ^uid and fragment("?::ltree @> ?::ltree", g.path, ^path),
        select: m.role
    )
    |> case do
      [] -> nil
      roles -> Enum.max_by(roles, &Role.rank/1)
    end
  end

  defp grant_role(uid, %Session{id: sid}) do
    role =
      Repo.one(
        from grant in ResourceGrant,
          where:
            grant.resource_type == :session and grant.resource_id == ^sid and
              grant.subject_type == :user and grant.subject_id == ^uid,
          select: grant.role,
          limit: 1
      )

    if role, do: {role, "grant"}, else: {nil, nil}
  end

  defp maybe_log(action, %Session{} = session, %Scope{user: user}, decision, reason) do
    if Role.mutating?(action) do
      %Decision{}
      |> Decision.create_changeset(%{
        subject_id: user && user.id,
        action: to_string(action),
        resource_type: "session",
        resource_id: session.id,
        decision: decision_tag(decision),
        reason: reason
      })
      |> Repo.insert()
    end

    :ok
  end

  defp decision_tag(:ok), do: "ok"
  defp decision_tag({:error, reason}), do: to_string(reason)

  @doc "Grants `role` on `resource` to `subject`. Requires :share. Upserts (re-grant updates the role)."
  @spec grant_access(
          Scope.t(),
          {:session, Ecto.UUID.t()},
          {:user | :group, Ecto.UUID.t()},
          Role.t()
        ) ::
          {:ok, ResourceGrant.t()} | {:error, term()}
  def grant_access(%Scope{} = scope, {:session, sid}, {subject_type, subject_id}, role) do
    with %Session{} = session <- Repo.get(Session, sid),
         :ok <- permit?(scope, :share, session) do
      %ResourceGrant{}
      |> ResourceGrant.create_changeset(%{
        resource_type: :session,
        resource_id: sid,
        subject_type: subject_type,
        subject_id: subject_id,
        role: role,
        granted_by: scope.user.id
      })
      |> Repo.insert(
        on_conflict: [set: [role: role]],
        conflict_target: [:resource_type, :resource_id, :subject_type, :subject_id]
      )
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Revokes `subject`'s grant on `resource`. Requires :share."
  @spec revoke_access(Scope.t(), {:session, Ecto.UUID.t()}, {:user | :group, Ecto.UUID.t()}) ::
          :ok | {:error, term()}
  def revoke_access(%Scope{} = scope, {:session, sid}, {subject_type, subject_id}) do
    with %Session{} = session <- Repo.get(Session, sid),
         :ok <- permit?(scope, :share, session) do
      {n, _} =
        Repo.delete_all(
          from g in ResourceGrant,
            where:
              g.resource_type == :session and g.resource_id == ^sid and
                g.subject_type == ^subject_type and g.subject_id == ^subject_id
        )

      if n > 0, do: :ok, else: {:error, :not_found}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Lists grants on `resource`. Requires :share."
  @spec list_grants(Scope.t(), {:session, Ecto.UUID.t()}) ::
          {:ok, [ResourceGrant.t()]} | {:error, term()}
  def list_grants(%Scope{} = scope, {:session, sid}) do
    with %Session{} = session <- Repo.get(Session, sid),
         :ok <- permit?(scope, :share, session) do
      {:ok,
       Repo.all(
         from g in ResourceGrant, where: g.resource_type == :session and g.resource_id == ^sid
       )}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Revokes every direct (user-subject) resource grant held by `user_id` on
  sessions owned by `org_id`. Used by SCIM deprovisioning so a deactivated member
  keeps no orphaned per-resource access. Returns the number of grants removed.
  """
  @spec revoke_user_grants_in_org(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def revoke_user_grants_in_org(user_id, org_id) do
    {count, _} =
      Repo.delete_all(
        from g in ResourceGrant,
          join: s in Session,
          on: g.resource_type == :session and g.resource_id == s.id,
          where:
            g.subject_type == :user and g.subject_id == ^user_id and
              s.organization_id == ^org_id
      )

    count
  end
end
