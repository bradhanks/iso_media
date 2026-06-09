defmodule PerfectPaper.Scim do
  @moduledoc """
  SCIM 2.0 service-provider context (Entra subset). The only SCIM-aware module
  and sole Repo boundary for `scim_tokens`. Translates SCIM operations into
  `Accounts`/`Organizations`/`Authz` calls; no SCIM vocabulary leaks into them.
  """
  import Ecto.Query, warn: false
  alias PerfectPaper.Repo
  alias PerfectPaper.Scim.Token
  alias PerfectPaper.{Accounts, Organizations, SSO, Events, Authz}
  alias PerfectPaper.Organizations.Organization

  @doc "Generates (or replaces) the org's SCIM token. Returns the plaintext ONCE."
  @spec generate_scim_token(Organization.t(), struct()) ::
          {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def generate_scim_token(%Organization{id: org_id}, creator) do
    plaintext = Token.generate_plaintext()

    Repo.transact(fn ->
      Repo.delete_all(from t in Token, where: t.organization_id == ^org_id)

      changeset =
        Token.create_changeset(%Token{}, %{
          organization_id: org_id,
          token_hash: Token.hash(plaintext),
          created_by: creator.id
        })

      with {:ok, _row} <- Repo.insert(changeset), do: {:ok, plaintext}
    end)
  end

  @doc "Rotates the org's SCIM token (delete + create). Returns new plaintext."
  @spec rotate_scim_token(Organization.t(), struct()) ::
          {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def rotate_scim_token(%Organization{} = org, creator), do: generate_scim_token(org, creator)

  @doc "Revokes (deletes) the org's SCIM token."
  @spec revoke_scim_token(Organization.t()) :: :ok
  def revoke_scim_token(%Organization{id: org_id}) do
    Repo.delete_all(from t in Token, where: t.organization_id == ^org_id)
    :ok
  end

  @doc "Returns the org's token row (for display: last_used_at, exists?)."
  @spec get_token_by_org(Ecto.UUID.t()) :: Token.t() | nil
  def get_token_by_org(org_id), do: Repo.get_by(Token, organization_id: org_id)

  @doc """
  Verifies an incoming plaintext SCIM token. Hashes it, looks up the row by hash,
  constant-time-compares, touches `last_used_at`, and returns the org id.
  """
  @spec verify_token(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, :unauthorized}
  def verify_token(plaintext) when is_binary(plaintext) and byte_size(plaintext) > 0 do
    hashed = Token.hash(plaintext)

    case Repo.get_by(Token, token_hash: hashed) do
      %Token{token_hash: stored, organization_id: org_id} = row ->
        if Plug.Crypto.secure_compare(hashed, stored) do
          Repo.update_all(from(t in Token, where: t.id == ^row.id),
            set: [last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)]
          )

          {:ok, org_id}
        else
          {:error, :unauthorized}
        end

      nil ->
        # Always run a comparison on the miss path so timing cannot distinguish
        # "no token with this hash" from "found but wrong" — prevents oracle attacks.
        Plug.Crypto.secure_compare(hashed, <<0::256>>)
        {:error, :unauthorized}
    end
  end

  def verify_token(_), do: {:error, :unauthorized}

  # ── Provisioning orchestration ──────────────────────────────────────────────

  @doc """
  Provisions (or reconciles) a user from a SCIM payload into the org. Enforces
  the org's verified email domain; writes a `scim:<org_id>` identity for
  correlation; ensures org membership. Idempotent on (external_id, email).
  """
  @spec provision_user(Organization.t(), map()) ::
          {:ok, Accounts.User.t()}
          | {:error, :domain_mismatch | :no_verified_domain | :invalid_user_name | term()}
  def provision_user(%Organization{id: org_id} = org, %{user_name: email} = attrs) do
    with :ok <- enforce_domain(org_id, email),
         {:ok, user} <- resolve_or_create_user(org_id, attrs),
         {:ok, _} <- ensure_scim_identity(org_id, user, attrs),
         {:ok, _} <- ensure_membership(org, user) do
      Events.emit(:"member.provisioned", %{
        organization_id: org_id,
        actor_id: nil,
        resource: %{type: :user, id: user.id},
        data: %{external_id: attrs[:external_id], via: :scim}
      })

      {:ok, user}
    end
  end

  @doc """
  Soft-deactivates a SCIM-provisioned user. Org-scoped: deactivates the
  membership, revokes the user's grants on this org's sessions, and only sets the
  GLOBAL deactivated flag (blocking all login + revoking sessions) when the user
  has no active membership in any other org.
  """
  @spec deactivate_user(Organization.t(), Ecto.UUID.t()) ::
          {:ok, Accounts.User.t() | nil} | {:error, :sole_owner | :not_found | term()}
  def deactivate_user(%Organization{id: org_id} = org, user_id) do
    with {:ok, _membership} <- Organizations.deactivate_membership(org, user_id) do
      Authz.revoke_user_grants_in_org(user_id, org_id)
      user = Repo.get(Accounts.User, user_id)

      result =
        if user && not Organizations.has_other_active_membership?(user_id, org_id) do
          Accounts.deactivate_user(user)
        else
          {:ok, user}
        end

      with {:ok, final_user} <- result do
        Events.emit(:"member.deactivated", %{
          organization_id: org_id,
          actor_id: nil,
          resource: %{type: :user, id: user_id},
          data: %{via: :scim}
        })

        {:ok, final_user}
      end
    end
  end

  @doc "Reactivates a previously deactivated user (membership + clears global flag)."
  @spec reactivate_user(Organization.t(), Ecto.UUID.t()) ::
          {:ok, Accounts.User.t() | nil} | {:error, term()}
  def reactivate_user(%Organization{id: org_id} = org, user_id) do
    with {:ok, _} <- Organizations.reactivate_membership(org, user_id) do
      user = Repo.get(Accounts.User, user_id)

      result =
        if user && user.deactivated_at do
          Accounts.reactivate_user(user)
        else
          {:ok, user}
        end

      with {:ok, _} <- result do
        Events.emit(:"member.reactivated", %{
          organization_id: org_id,
          actor_id: nil,
          resource: %{type: :user, id: user_id},
          data: %{via: :scim}
        })

        {:ok, Repo.get(Accounts.User, user_id)}
      end
    end
  end

  @doc """
  Creates/updates a flat SCIM-managed group and reconciles its membership.
  Member ids are filtered to users that exist (an IdP may reference a purged id).
  """
  @spec sync_group(Organization.t(), map()) ::
          {:ok, Organizations.Group.t()} | {:error, term()}
  def sync_group(%Organization{id: org_id} = org, %{external_id: ext, display_name: name} = attrs) do
    member_ids = attrs |> Map.get(:member_ids, []) |> Accounts.existing_user_ids()

    group_result =
      case Organizations.get_group_by_scim_id(org_id, ext) do
        nil ->
          Organizations.create_group(org, %{
            name: name,
            kind: :group,
            scim_managed: true,
            scim_external_id: ext
          })

        %Organizations.Group{} = g ->
          Organizations.update_group(g, %{name: name})
      end

    with {:ok, group} <- group_result do
      :ok = Organizations.set_group_members(group, member_ids)

      Events.emit(:"group.synced", %{
        organization_id: org_id,
        actor_id: nil,
        resource: %{type: :group, id: group.id},
        data: %{external_id: ext}
      })

      {:ok, group}
    end
  end

  # Fetches a SCIM group scoped to its org, guarding a malformed (non-UUID) id so
  # a bad path id yields not-found, not an Ecto.Query.CastError (500).
  defp scim_group(org_id, group_id) do
    if PerfectPaper.UUID.valid?(group_id),
      do: Repo.get_by(Organizations.Group, id: group_id, organization_id: org_id),
      else: nil
  end

  @doc "Deletes a SCIM-managed group and its memberships."
  @spec delete_group(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, :deleted} | {:error, :not_found}
  def delete_group(org_id, group_id) do
    case scim_group(org_id, group_id) do
      nil ->
        {:error, :not_found}

      group ->
        Repo.delete_all(from gm in Organizations.GroupMembership, where: gm.group_id == ^group.id)

        Repo.delete(group)
        {:ok, :deleted}
    end
  end

  # ── private orchestration helpers ───────────────────────────────────────────

  defp enforce_domain(_org_id, email) when not is_binary(email), do: {:error, :invalid_user_name}

  defp enforce_domain(org_id, email) do
    case SSO.get_config_by_org_id(org_id) do
      %{email_domain: domain} ->
        provided = email |> String.split("@") |> List.last() |> String.downcase()
        if provided == String.downcase(domain), do: :ok, else: {:error, :domain_mismatch}

      _ ->
        {:error, :no_verified_domain}
    end
  end

  defp resolve_or_create_user(org_id, %{external_id: ext, user_name: email}) do
    case Accounts.get_user_by_identity("scim:#{org_id}", ext) do
      %Accounts.User{} = user -> {:ok, user}
      nil -> Accounts.find_or_provision_member(email)
    end
  end

  defp ensure_scim_identity(org_id, user, %{external_id: ext, user_name: email}) do
    provider = "scim:#{org_id}"

    case Accounts.get_user_by_identity(provider, ext) do
      %Accounts.User{} ->
        {:ok, :exists}

      nil ->
        Accounts.create_identity(user, %{
          provider: provider,
          provider_uid: ext,
          provider_email: email
        })
    end
  end

  defp ensure_membership(org, user) do
    case Organizations.get_membership(org.id, user.id) do
      nil -> Organizations.add_member(org, user, :member)
      membership -> {:ok, membership}
    end
  end

  # ── User read surface (controllers) ─────────────────────────────────────────

  @doc "Lists SCIM User resources for the org honoring an `eq` filter. No match → []."
  @spec list_users(Ecto.UUID.t(), PerfectPaper.Scim.FilterParser.result()) :: [map()]
  def list_users(org_id, filter) do
    org_id
    |> matching_memberships(filter)
    |> Enum.map(fn {user, membership, ext} ->
      PerfectPaper.Scim.User.render(user, membership, ext)
    end)
  end

  @doc "Gets one SCIM User resource by internal id (scoped to org), or `:not_found`."
  @spec get_user_resource(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def get_user_resource(org_id, user_id) do
    case Organizations.get_membership(org_id, user_id) do
      nil ->
        {:error, :not_found}

      membership ->
        user = Repo.get!(Accounts.User, user_id)
        {:ok, PerfectPaper.Scim.User.render(user, membership, scim_external_id(org_id, user_id))}
    end
  end

  # Returns [{user, membership, external_id}] for the org, filtered. `:no_match`
  # / unsupported filters yield [] — never an error (Entra Test-Connection).
  defp matching_memberships(org_id, filter) do
    base =
      from(m in Organizations.Membership,
        join: u in Accounts.User,
        on: u.id == m.user_id,
        where: m.organization_id == ^org_id,
        select: {u, m}
      )

    query =
      case filter do
        # RFC 7643: userName matching is case-insensitive. Compare lowercased so a
        # mixed-case Entra query finds the existing row (else it dup-provisions).
        {:eq, :user_name, email} ->
          downcase_email = String.downcase(email)
          from([_m, u] in base, where: fragment("lower(?)", u.email) == ^downcase_email)

        {:eq, :external_id, ext} ->
          ids = identity_user_ids(org_id, ext)
          from([_m, u] in base, where: u.id in ^ids)

        _ ->
          from([_m, _u] in base, where: false)
      end

    query
    |> Repo.all()
    |> Enum.map(fn {u, m} -> {u, m, scim_external_id(org_id, u.id)} end)
  end

  defp identity_user_ids(org_id, ext) do
    Repo.all(
      from i in Accounts.UserIdentity,
        where: i.provider == ^"scim:#{org_id}" and i.provider_uid == ^ext,
        select: i.user_id
    )
  end

  defp scim_external_id(org_id, user_id) do
    Repo.one(
      from i in Accounts.UserIdentity,
        where: i.provider == ^"scim:#{org_id}" and i.user_id == ^user_id,
        select: i.provider_uid
    )
  end

  # ── Group read surface + PATCH (controllers) ────────────────────────────────

  @doc "Member user ids of a group (for rendering)."
  @spec group_member_ids(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def group_member_ids(group_id),
    do:
      Repo.all(
        from gm in Organizations.GroupMembership,
          where: gm.group_id == ^group_id,
          select: gm.user_id
      )

  @doc "Lists SCIM Group resources for the org honoring an `eq` filter. No match → []."
  @spec list_groups(Ecto.UUID.t(), PerfectPaper.Scim.FilterParser.result()) :: [map()]
  def list_groups(org_id, filter) do
    query =
      case filter do
        {:eq, :display_name, name} ->
          from(g in Organizations.Group,
            where: g.organization_id == ^org_id and g.name == ^name and g.scim_managed == true
          )

        {:eq, :external_id, ext} ->
          from(g in Organizations.Group,
            where: g.organization_id == ^org_id and g.scim_external_id == ^ext
          )

        _ ->
          from(g in Organizations.Group, where: false)
      end

    query |> Repo.all() |> Enum.map(&PerfectPaper.Scim.Group.render(&1, group_member_ids(&1.id)))
  end

  @doc "Gets one SCIM Group resource by internal id (scoped to org), or `:not_found`."
  @spec get_group_resource(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def get_group_resource(org_id, group_id) do
    case scim_group(org_id, group_id) do
      nil -> {:error, :not_found}
      group -> {:ok, PerfectPaper.Scim.Group.render(group, group_member_ids(group.id))}
    end
  end

  @doc """
  Applies parsed group PATCH ops (member add/remove/replace, rename) atomically.
  Threads the membership set through the reduce so a single body with both add
  and remove applies cumulatively; halts and rolls back on any op failure.
  Member ids are filtered to existing users (FK safety).
  """
  @spec patch_group(Organization.t(), Ecto.UUID.t(), [PerfectPaper.Scim.PatchParser.op()]) ::
          :ok | {:error, :not_found | term()}
  def patch_group(%Organization{id: org_id}, group_id, ops) do
    case scim_group(org_id, group_id) do
      nil ->
        {:error, :not_found}

      group ->
        outcome =
          Repo.transact(fn ->
            # Lock the group FIRST so the snapshot below + every set_group_members
            # call run under one lock — no lost update across concurrent PATCHes.
            _ = Organizations.lock_group(group_id)

            Enum.reduce_while(ops, {:ok, MapSet.new(group_member_ids(group_id))}, fn op,
                                                                                     {:ok, acc} ->
              case apply_group_op(group, op, acc) do
                {:ok, new_acc} -> {:cont, {:ok, new_acc}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)
            |> case do
              {:ok, _set} -> {:ok, :ok}
              {:error, reason} -> {:error, reason}
            end
          end)

        case outcome do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp apply_group_op(group, {:add_members, ids}, acc) do
    new_set = MapSet.union(acc, MapSet.new(Accounts.existing_user_ids(ids)))
    Organizations.set_group_members(group, MapSet.to_list(new_set))
    {:ok, new_set}
  end

  defp apply_group_op(group, {:remove_members, ids}, acc) do
    new_set = MapSet.difference(acc, MapSet.new(ids))
    Organizations.set_group_members(group, MapSet.to_list(new_set))
    {:ok, new_set}
  end

  defp apply_group_op(group, {:replace_members, ids}, _acc) do
    clean = Accounts.existing_user_ids(ids)
    Organizations.set_group_members(group, clean)
    {:ok, MapSet.new(clean)}
  end

  defp apply_group_op(group, {:set_display_name, name}, acc) do
    case Organizations.update_group(group, %{name: name}) do
      {:ok, _} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_group_op(_group, _other, acc), do: {:ok, acc}
end
