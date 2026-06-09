defmodule PerfectPaper.Organizations do
  @moduledoc """
  Organizations group users under a shared credit pool. Owners control the pool
  and may allocate credits to members; members may request credits from the pool.

  This is the public API and the only `Repo` boundary for the Organizations context.
  """
  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.Organizations.{Organization, Membership, Group, GroupMembership, Notifier}

  # ── Creating organizations ─────────────────────────────────────────────────

  @doc "Creates a new organization owned by the given user."
  @spec create_organization(struct(), map()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t()}
  def create_organization(owner, attrs \\ %{}) do
    attrs = Map.put(attrs, :owner_id, owner.id)

    %Organization{}
    |> Organization.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches an organization by id.

  Returns `{:ok, org}` or `{:error, :not_found}`. Use this from the web layer
  when an org id arrives in a path (e.g. the SSO management surface) — do not
  reach into `Repo` directly.

  The id is cast before querying: a malformed (non-UUID) string yields
  `{:error, :not_found}` rather than raising `Ecto.Query.CastError`, so callers
  return 404 instead of 500 on garbage path segments.
  """
  @spec get_organization(Ecto.UUID.t()) ::
          {:ok, Organization.t()} | {:error, :not_found}
  def get_organization(org_id) when is_binary(org_id) do
    case Ecto.UUID.cast(org_id) do
      {:ok, id} ->
        case Repo.get(Organization, id) do
          nil -> {:error, :not_found}
          org -> {:ok, org}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def get_organization(_), do: {:error, :not_found}

  @doc "Fetches an organization by id, raising if not found. For callers that already hold a trusted id (e.g. a resolved SCIM token)."
  @spec get_organization!(Ecto.UUID.t()) :: Organization.t()
  def get_organization!(org_id), do: Repo.get!(Organization, org_id)

  # ── Managing members ───────────────────────────────────────────────────────

  @doc "Adds a user to an organization with the given role (default: :member)."
  @spec add_member(Organization.t(), struct(), atom()) ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def add_member(%Organization{} = org, user, role \\ :member) do
    %Membership{}
    |> Membership.create_changeset(%{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })
    |> Repo.insert()
  end

  # ── Membership lifecycle (directory provisioning / deprovisioning) ──────────

  @doc "Looks up a user's membership in an org (nil if none)."
  @spec get_membership(Ecto.UUID.t(), Ecto.UUID.t()) :: Membership.t() | nil
  def get_membership(org_id, user_id) do
    # Guard malformed ids (e.g. a non-UUID SCIM path id) → nil, never a CastError/500.
    if PerfectPaper.UUID.valid?(org_id) and PerfectPaper.UUID.valid?(user_id),
      do: Repo.get_by(Membership, organization_id: org_id, user_id: user_id),
      else: nil
  end

  @doc """
  True when `user_id` is the organization's canonical owner (`owner_id`).
  Deactivating them via the directory would orphan the org, so it is blocked.
  """
  @spec sole_owner?(Organization.t(), Ecto.UUID.t()) :: boolean()
  def sole_owner?(%Organization{owner_id: owner_id}, user_id), do: owner_id == user_id

  @doc """
  Deactivates a member: marks the membership `:deactivated`, strips all of the
  user's group memberships in this org, and refuses to deactivate the org owner
  (`{:error, :sole_owner}`).
  """
  @spec deactivate_membership(Organization.t(), Ecto.UUID.t()) ::
          {:ok, Membership.t()} | {:error, :not_found | :sole_owner}
  def deactivate_membership(%Organization{id: org_id} = org, user_id) do
    cond do
      sole_owner?(org, user_id) ->
        {:error, :sole_owner}

      membership = get_membership(org_id, user_id) ->
        Repo.transact(fn ->
          Repo.delete_all(
            from gm in GroupMembership,
              join: g in Group,
              on: g.id == gm.group_id,
              where: gm.user_id == ^user_id and g.organization_id == ^org_id
          )

          Repo.update(Membership.status_changeset(membership, :deactivated))
        end)

      true ->
        {:error, :not_found}
    end
  end

  @doc "Reactivates a previously deactivated membership (groups are re-synced by the IdP)."
  @spec reactivate_membership(Organization.t(), Ecto.UUID.t()) ::
          {:ok, Membership.t()} | {:error, :not_found}
  def reactivate_membership(%Organization{id: org_id}, user_id) do
    case get_membership(org_id, user_id) do
      nil -> {:error, :not_found}
      membership -> Repo.update(Membership.status_changeset(membership, :active))
    end
  end

  @doc "Soft-removes a member (delegates to deactivate — no hard delete)."
  @spec remove_member(Organization.t(), Ecto.UUID.t()) ::
          {:ok, Membership.t()} | {:error, :not_found | :sole_owner}
  def remove_member(%Organization{} = org, user_id), do: deactivate_membership(org, user_id)

  @doc """
  True when the user holds an `:active` membership in some org OTHER than
  `except_org_id`. SCIM uses this to decide whether deprovisioning from one org
  should also globally deactivate the user (only when no other org keeps them).
  """
  @spec has_other_active_membership?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def has_other_active_membership?(user_id, except_org_id) do
    Repo.exists?(
      from m in Membership,
        where:
          m.user_id == ^user_id and m.organization_id != ^except_org_id and
            m.status == :active
    )
  end

  # ── Group lifecycle (SCIM-managed) ──────────────────────────────────────────

  @doc "Renames/updates a group's mutable attributes."
  @spec update_group(Group.t(), map()) :: {:ok, Group.t()} | {:error, Ecto.Changeset.t()}
  def update_group(%Group{} = group, attrs),
    do: group |> Group.update_changeset(attrs) |> Repo.update()

  @doc "Fetches a SCIM-managed group by its external id within an org (nil if none)."
  @spec get_group_by_scim_id(Ecto.UUID.t(), String.t()) :: Group.t() | nil
  def get_group_by_scim_id(org_id, external_id),
    do: Repo.get_by(Group, organization_id: org_id, scim_external_id: external_id)

  @doc """
  Idempotently reconciles a group's membership to exactly `user_ids`: adds the
  missing, removes the absent, leaves the rest. Re-adding an existing member is a
  success (no error) — required for Entra's repeated group PATCHes.
  """
  @spec set_group_members(Group.t(), [Ecto.UUID.t()]) :: :ok
  def set_group_members(%Group{id: group_id, organization_id: org_id}, user_ids) do
    Repo.transact(fn ->
      # Serialize concurrent reconciles of the same group (lost-update defense):
      # take the lock, THEN read current state under it.
      _ = lock_group(group_id)

      # Only ACTIVE members of THIS group's org may be added — never inject a
      # foreign-org user (which would grant cross-tenant access via group-path
      # inheritance + leak a user-existence oracle to the IdP).
      desired =
        from(m in Membership,
          where: m.organization_id == ^org_id and m.user_id in ^user_ids and m.status == :active,
          select: m.user_id
        )
        |> Repo.all()
        |> MapSet.new()

      current =
        from(gm in GroupMembership, where: gm.group_id == ^group_id, select: gm.user_id)
        |> Repo.all()
        |> MapSet.new()

      Enum.each(MapSet.difference(desired, current), fn uid ->
        %GroupMembership{}
        |> GroupMembership.create_changeset(%{group_id: group_id, user_id: uid, role: :viewer})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:group_id, :user_id])
      end)

      to_remove = MapSet.difference(current, desired)

      if MapSet.size(to_remove) > 0 do
        remove_list = MapSet.to_list(to_remove)

        Repo.delete_all(
          from gm in GroupMembership,
            where: gm.group_id == ^group_id and gm.user_id in ^remove_list
        )
      end

      {:ok, :ok}
    end)

    :ok
  end

  @doc """
  Takes a row-level write lock on a group. Call inside a transaction so that a
  group-membership reconcile (and any multi-step PATCH driving it) serializes
  against concurrent reconciles of the same group.
  """
  @spec lock_group(Ecto.UUID.t()) :: Group.t() | nil
  def lock_group(group_id) do
    Repo.one(from g in Group, where: g.id == ^group_id, lock: "FOR UPDATE")
  end

  # ── Credit pool operations ─────────────────────────────────────────────────

  @doc "Count of `:active` memberships in the org (billable seats — drives seat billing)."
  @spec active_member_count(Ecto.UUID.t()) :: non_neg_integer()
  def active_member_count(org_id) do
    Repo.one(
      from m in Membership,
        where: m.organization_id == ^org_id and m.status == :active,
        select: count(m.id)
    )
  end

  @doc """
  Atomically adds `amount` credits to the org pool (no read-modify-write).
  Bypasses the pool changeset by design — funding/clawback is privileged and may
  push a contract-backed pool above any cap or below zero.
  """
  @spec fund_pool(Ecto.UUID.t(), integer()) :: :ok
  def fund_pool(org_id, amount) do
    Repo.update_all(from(o in Organization, where: o.id == ^org_id), inc: [credit_pool: amount])
    :ok
  end

  @doc """
  Charges `amount` credits to the org pool for an org-owned review. Fast path: an
  atomic conditional decrement when the pool stays non-negative (no contract
  query). Slow path (would go negative): allowed only under a date-aware active
  contract AND while staying at/above the soft floor
  `−(seats × per_seat_credits × 2)` (via `Billing.contract_floor/1`).
  """
  @spec charge_pool(Ecto.UUID.t(), pos_integer()) :: :ok | {:error, :insufficient_credits}
  def charge_pool(org_id, amount) when amount > 0 do
    {fast, _} =
      Repo.update_all(
        from(o in Organization, where: o.id == ^org_id and o.credit_pool >= ^amount),
        inc: [credit_pool: -amount]
      )

    if fast == 1 do
      :ok
    else
      case PerfectPaper.Billing.contract_floor(org_id) do
        {:ok, floor} ->
          {slow, _} =
            Repo.update_all(
              from(o in Organization,
                where: o.id == ^org_id and o.credit_pool - ^amount >= ^floor
              ),
              inc: [credit_pool: -amount]
            )

          if slow == 1, do: :ok, else: {:error, :insufficient_credits}

        :none ->
          {:error, :insufficient_credits}
      end
    end
  end

  @doc """
  Best-effort read of whether the org pool can absorb a charge of `amount` right
  now, mirroring `charge_pool/2`'s fast-path + contract-floor rule. The
  authoritative gate is `charge_pool/2` (atomic, under lock); this is the
  pre-charge peek used to avoid paying for a review the pool can't fund.
  """
  @spec pool_affordable?(Ecto.UUID.t(), pos_integer()) :: boolean()
  def pool_affordable?(org_id, amount) when amount > 0 do
    if PerfectPaper.UUID.valid?(org_id) do
      case Repo.one(from(o in Organization, where: o.id == ^org_id, select: o.credit_pool)) do
        nil ->
          false

        pool when pool >= amount ->
          true

        pool ->
          case PerfectPaper.Billing.contract_floor(org_id) do
            {:ok, floor} -> pool - amount >= floor
            :none -> false
          end
      end
    else
      false
    end
  end

  @doc """
  Returns the credit pool status for an organization:
  - `pool` — the total credits in the organization's pool
  - `allocated` — the sum of credits allocated to members
  - `available` — pool minus allocated
  """
  @spec credit_pool_status(Ecto.UUID.t()) ::
          %{pool: integer(), allocated: integer(), available: integer()}
  def credit_pool_status(org_id) do
    org = Repo.get!(Organization, org_id)
    allocated = allocated_credits(org_id)
    %{pool: org.credit_pool, allocated: allocated, available: org.credit_pool - allocated}
  end

  @doc """
  Allocates `amount` credits from the organization's pool to a specific member.

  Decrements `organizations.credit_pool` by `amount` and increments the member's
  `allocated_credits` by the same amount. Returns `{:error, :insufficient_pool}`
  if the pool does not have enough available credits.
  """
  @spec allocate_credits_to_member(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Membership.t()} | {:error, :insufficient_pool | term()}
  def allocate_credits_to_member(org_id, user_id, amount) when amount > 0 do
    # Lock the org row FOR UPDATE and recompute availability inside the
    # transaction, so two concurrent allocations can't both pass the
    # sufficiency check against a stale pool and over-allocate (lost update).
    Repo.transaction(fn ->
      with {:ok, org} <- lock_org(org_id),
           {:ok, membership} <- fetch_membership(org_id, user_id),
           available = org.credit_pool - allocated_credits(org_id),
           :ok <- check_sufficient_pool(available, amount),
           {:ok, _org} <-
             Repo.update(
               Organization.pool_changeset(org, %{credit_pool: org.credit_pool - amount})
             ),
           {:ok, updated} <-
             Repo.update(
               Membership.allocation_changeset(membership, %{
                 allocated_credits: membership.allocated_credits + amount
               })
             ) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Returns `amount` credits from a member's allocation back to the organization pool.

  Increments `organizations.credit_pool` by `amount` and decrements the member's
  `allocated_credits` by the same amount. The member's allocated_credits are
  clamped at 0 (cannot go below zero).
  """
  @spec return_credits_to_pool(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Membership.t()} | {:error, term()}
  def return_credits_to_pool(org_id, user_id, amount) when amount > 0 do
    # Same row-lock discipline as allocate: serialize pool mutations per org so a
    # concurrent allocation/return can't clobber the pool via a lost update.
    Repo.transaction(fn ->
      with {:ok, org} <- lock_org(org_id),
           {:ok, membership} <- fetch_membership(org_id, user_id),
           actual_return = min(amount, membership.allocated_credits),
           {:ok, _org} <-
             Repo.update(
               Organization.pool_changeset(org, %{credit_pool: org.credit_pool + actual_return})
             ),
           {:ok, updated} <-
             Repo.update(
               Membership.allocation_changeset(membership, %{
                 allocated_credits: membership.allocated_credits - actual_return
               })
             ) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  A member requests credits from the organization's pool.

  Only org owners and admins may self-approve. This is a simplification until
  a requests/approval table exists — at that point non-admins will be able to
  submit requests that pend admin review. For now, only admins may call this.
  """
  @spec request_credits(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Membership.t()} | {:error, :unauthorized | :insufficient_pool | term()}
  def request_credits(org_id, user_id, amount) do
    if admin?(org_id, user_id) do
      allocate_credits_to_member(org_id, user_id, amount)
    else
      {:error, :unauthorized}
    end
  end

  @doc "Invites someone by email to join the given organization."
  @spec send_invitation(Organization.t(), String.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def send_invitation(%Organization{name: name}, invitee_email, accept_url) do
    Notifier.deliver_invitation(invitee_email, name, accept_url)
  end

  # ── Group tree ────────────────────────────────────────────────────────────

  @doc """
  Creates a group in `org`. Pass `:parent_id` to nest it; omit for a top-level
  group. Computes the ltree `path` (ancestor ids, hyphens stripped) here so the
  schema changeset stays pure.
  """
  @spec create_group(Organization.t(), map()) ::
          {:ok, Group.t()} | {:error, Ecto.Changeset.t() | :parent_not_found}
  def create_group(%Organization{} = org, attrs) do
    attrs = Map.new(attrs)
    id = Ecto.UUID.generate()

    with {:ok, parent_path} <- parent_path(org.id, attrs[:parent_id]) do
      path = join_path(parent_path, id)

      %Group{}
      |> Group.create_changeset(%{
        id: id,
        organization_id: org.id,
        parent_id: attrs[:parent_id],
        name: attrs[:name],
        kind: attrs[:kind] || :group,
        path: path,
        scim_managed: attrs[:scim_managed] || false,
        scim_external_id: attrs[:scim_external_id]
      })
      |> Repo.insert()
    end
  end

  @doc "Adds a user to a group with a role (default :viewer)."
  @spec add_group_member(Group.t(), struct(), atom()) ::
          {:ok, GroupMembership.t()} | {:error, Ecto.Changeset.t()}
  def add_group_member(%Group{} = group, user, role \\ :viewer) do
    %GroupMembership{}
    |> GroupMembership.create_changeset(%{group_id: group.id, user_id: user.id, role: role})
    |> Repo.insert()
  end

  @doc "ltree paths of every group `user_id` holds a role at (for authz scoping)."
  @spec authorized_group_paths(Ecto.UUID.t()) :: [String.t()]
  def authorized_group_paths(user_id) do
    Repo.all(
      from m in GroupMembership,
        join: g in Group,
        on: g.id == m.group_id,
        where: m.user_id == ^user_id,
        select: g.path
    )
  end

  # ── Admin org resolution ──────────────────────────────────────────────────

  @doc """
  Returns all organizations in which `user_id` is an owner or admin.

  Used by the webhook REST controller (and any other surface that must resolve
  the caller's administering org) to find the org(s) the request applies to.
  Most users have exactly one admin org; callers should handle the empty-list
  and multi-org cases explicitly.
  """
  @spec admin_orgs(Ecto.UUID.t()) :: [Organization.t()]
  def admin_orgs(user_id) do
    Repo.all(
      from o in Organization,
        left_join: m in Membership,
        on:
          m.organization_id == o.id and m.user_id == ^user_id and
            m.role in [:owner, :admin] and m.status == :active,
        where: o.owner_id == ^user_id or not is_nil(m.id),
        distinct: o.id,
        order_by: o.inserted_at
    )
  end

  # ── Org admin check ───────────────────────────────────────────────────────

  @doc """
  Returns `true` when `user_id` is an owner or admin of the given org.

  Accepts either an `Organization` struct or a bare `org_id` (binary UUID).
  When an org_id is given, any membership with role `:owner` or `:admin` is
  checked (there is no org struct to compare `owner_id` against directly, so
  both owner and admin roles are queried from the memberships table).

  Use this from other contexts that need to gate on org-admin status — do not
  duplicate the membership-role logic outside `Organizations`.
  """
  @spec admin?(Organization.t() | Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def admin?(%Organization{} = org, user_id), do: org_admin?(org, user_id)

  def admin?(org_id, user_id) when is_binary(org_id) do
    Repo.exists?(
      from m in Membership,
        where:
          m.organization_id == ^org_id and m.user_id == ^user_id and
            m.role in [:owner, :admin] and m.status == :active
    ) or
      Repo.exists?(
        from o in Organization,
          where: o.id == ^org_id and o.owner_id == ^user_id
      )
  end

  # ── MFA policy ────────────────────────────────────────────────────────────

  @doc """
  Sets an organization's MFA-required policy. Only an org owner or admin may.

  Authorized via an org-level role check; TODO(mfa): move org-resource
  authorization into `Authz.permit?` when the org-admin surface lands.
  """
  @spec set_mfa_required(Organization.t(), PerfectPaper.Accounts.Scope.t(), boolean()) ::
          {:ok, Organization.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def set_mfa_required(
        %Organization{} = org,
        %PerfectPaper.Accounts.Scope{user: %{id: uid}},
        required
      )
      when is_boolean(required) do
    if admin?(org, uid) do
      org |> Ecto.Changeset.change(%{mfa_required: required}) |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc "Whether any organization the user belongs to (or owns) requires MFA."
  @spec mfa_required_for_user?(Ecto.UUID.t()) :: boolean()
  def mfa_required_for_user?(user_id) do
    Repo.exists?(
      from o in Organization,
        left_join: m in Membership,
        on: m.organization_id == o.id,
        where: o.mfa_required and (o.owner_id == ^user_id or m.user_id == ^user_id)
    )
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  # Guard clause must come first: exact owner match avoids a DB round-trip.
  defp org_admin?(%Organization{owner_id: owner_id}, uid) when owner_id == uid, do: true

  defp org_admin?(%Organization{id: org_id}, uid) do
    Repo.exists?(
      from m in Membership,
        where:
          m.organization_id == ^org_id and m.user_id == ^uid and
            m.role in [:owner, :admin] and m.status == :active
    )
  end

  # Fetches an org while taking a row-level write lock; call inside a transaction
  # so concurrent pool mutations on the same org serialize.
  defp lock_org(org_id) do
    case Repo.one(from o in Organization, where: o.id == ^org_id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      org -> {:ok, org}
    end
  end

  defp allocated_credits(org_id) do
    Repo.one(
      from m in Membership,
        where: m.organization_id == ^org_id,
        select: coalesce(sum(m.allocated_credits), 0)
    )
  end

  defp fetch_membership(org_id, user_id) do
    case Repo.one(
           from m in Membership,
             where: m.organization_id == ^org_id and m.user_id == ^user_id
         ) do
      nil -> {:error, :membership_not_found}
      membership -> {:ok, membership}
    end
  end

  defp check_sufficient_pool(available, amount) when available >= amount, do: :ok
  defp check_sufficient_pool(_available, _amount), do: {:error, :insufficient_pool}

  # path of the parent group, validated to belong to the same org; "" when top-level.
  defp parent_path(_org_id, nil), do: {:ok, ""}

  defp parent_path(org_id, parent_id) do
    case Repo.one(from g in Group, where: g.id == ^parent_id and g.organization_id == ^org_id) do
      nil -> {:error, :parent_not_found}
      %Group{path: path} -> {:ok, path}
    end
  end

  defp join_path("", id), do: label(id)
  defp join_path(parent_path, id), do: parent_path <> "." <> label(id)

  defp label(id), do: String.replace(id, "-", "")
end
