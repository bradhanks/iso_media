defmodule PerfectPaper.Teams do
  @moduledoc """
  Microsoft Teams bot context — the only Teams-aware module and the sole `Repo`
  boundary for `teams_links`. Validates-then-handles inbound Activities (link /
  command), issues/redeems the stateless deep-link fallback token, and dispatches
  proactive cards. Calls `Accounts` / `SSO` / `History` through their public APIs
  only.

  ## Security

  Every inbound Activity reaches `handle_activity/2` **only after** the controller
  has validated the Bot Framework JWT, so the `aad_object_id`, `tenant_id`, and
  `conversation_reference` carried by the Activity are trusted. Linking is
  **tenant-scoped**: an AAD object id is matched to a PerfectPaper user via
  `Accounts.get_oidc_identity_by_oid/1`, and the matched org's verified SSO config
  `oidc_tenant_id` must equal the Activity's tenant id — otherwise no link is
  created and the user is shown the deep-link fallback prompt.
  """
  import Ecto.Query, warn: false

  alias PerfectPaper.{Repo, Accounts, SSO, History}
  alias PerfectPaper.Accounts.Scope
  alias PerfectPaper.Teams.{Link, Activity, Card, Bot}

  @link_salt "teams-link"
  @link_max_age 900

  # ── Links ────────────────────────────────────────────────────────────────

  @doc "Returns the Teams link for the given user id, or `nil`."
  @spec get_link_by_user(Ecto.UUID.t()) :: Link.t() | nil
  def get_link_by_user(user_id), do: Repo.get_by(Link, user_id: user_id)

  @doc "Returns the Teams link for the given AAD object id, or `nil`."
  @spec get_link_by_oid(String.t()) :: Link.t() | nil
  def get_link_by_oid(oid), do: Repo.get_by(Link, aad_object_id: oid)

  @doc "Removes the user's Teams link (idempotent). Always returns `:ok`."
  @spec unlink(Ecto.UUID.t()) :: :ok
  def unlink(user_id) do
    Repo.delete_all(from l in Link, where: l.user_id == ^user_id)
    :ok
  end

  # Upserts the link, keyed by `:user_id` so a re-install refreshes the stored
  # AAD/tenant/serviceUrl/conversation_reference rather than colliding.
  @spec upsert_link(map()) :: {:ok, Link.t()} | {:error, Ecto.Changeset.t()}
  defp upsert_link(attrs) do
    %Link{}
    |> Link.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:aad_object_id, :tenant_id, :service_url, :conversation_reference, :updated_at]},
      conflict_target: :user_id
    )
  end

  # ── Inbound activity handling (called AFTER JWT validation by the controller) ──

  @doc """
  Handles a parsed, JWT-verified inbound Activity: links the user on an install
  event (`conversationUpdate` / `installationUpdate`), or runs a command on a
  `message`. Always returns `:ok`.
  """
  @spec handle_activity(Activity.t(), map()) :: :ok
  def handle_activity(%Activity{type: type} = act, _ctx)
      when type in ["conversationUpdate", "installationUpdate"] do
    link_from_activity(act)
    :ok
  end

  def handle_activity(%Activity{type: "message"} = act, _ctx) do
    case Activity.command(act) do
      "status" -> reply_status(act)
      "mute" -> toggle_mute(act, true)
      "unmute" -> toggle_mute(act, false)
      _ -> Bot.reply(act.conversation_reference, Card.help())
    end

    :ok
  end

  def handle_activity(%Activity{}, _ctx), do: :ok

  # Tenant-scoped AAD link, else a deep-link fallback prompt. An Activity with no
  # AAD object id can never be matched, so it always falls back to the prompt.
  @spec link_from_activity(Activity.t()) :: :ok | {:error, term()}
  defp link_from_activity(%Activity{aad_object_id: nil} = act),
    do: Bot.reply(act.conversation_reference, link_prompt_card(act))

  defp link_from_activity(%Activity{aad_object_id: oid, tenant_id: tenant} = act) do
    with %{user: user, org_id: org_id} <- Accounts.get_oidc_identity_by_oid(oid),
         %{oidc_tenant_id: ^tenant} <- SSO.get_config_by_org_id(org_id) do
      {:ok, _link} =
        upsert_link(%{
          user_id: user.id,
          aad_object_id: oid,
          tenant_id: tenant,
          service_url: act.service_url,
          conversation_reference: act.conversation_reference
        })

      Bot.reply(act.conversation_reference, Card.welcome(user.email))
    else
      _ -> Bot.reply(act.conversation_reference, link_prompt_card(act))
    end
  end

  # Toggles the mute flag on the link behind the Activity's AAD oid. If the oid is
  # not linked, prompts the user to connect instead.
  @spec toggle_mute(Activity.t(), boolean()) :: :ok | {:error, term()}
  defp toggle_mute(%Activity{aad_object_id: oid} = act, muted) do
    case get_link_by_oid(oid) do
      nil ->
        Bot.reply(act.conversation_reference, link_prompt_card(act))

      link ->
        {:ok, _link} = Repo.update(Link.mute_changeset(link, muted))
        Bot.reply(act.conversation_reference, Card.help())
    end
  end

  # Replies with the linked user's recent sessions. `processing_status` is a
  # non-null Ecto.Enum atom (default :pending), so to_string/1 always yields a
  # human-readable state.
  @spec reply_status(Activity.t()) :: :ok | {:error, term()}
  defp reply_status(%Activity{aad_object_id: oid} = act) do
    case get_link_by_oid(oid) do
      nil ->
        Bot.reply(act.conversation_reference, link_prompt_card(act))

      link ->
        scope = Scope.for_user(Accounts.get_user!(link.user_id))

        sessions =
          scope
          |> History.list_sessions(limit: 5)
          |> Enum.map(&%{title: &1.title, state: to_string(&1.processing_status)})

        Bot.reply(act.conversation_reference, Card.status(sessions))
    end
  end

  # Builds the deep-link fallback card: a short-lived token carrying the Teams
  # identity, wrapped in a button that deep-links into the web app to finish
  # linking once the user authenticates there.
  @spec link_prompt_card(Activity.t()) :: map()
  defp link_prompt_card(%Activity{} = act) do
    token =
      issue_link_token(%{
        aad_object_id: act.aad_object_id,
        tenant_id: act.tenant_id,
        conversation_reference: act.conversation_reference,
        service_url: act.service_url
      })

    Card.link_prompt(PerfectPaperWeb.Endpoint.url() <> "/teams/link?token=" <> token)
  end

  # ── Deep-link fallback token (stateless) ──────────────────────────────────

  @doc """
  Signs a short-lived (15 min) deep-link token carrying the Teams identity to bind.
  The payload typically holds `:aad_object_id`, `:tenant_id`, `:service_url`, and
  the `:conversation_reference`.
  """
  @spec issue_link_token(map()) :: String.t()
  def issue_link_token(payload),
    do: Phoenix.Token.sign(PerfectPaperWeb.Endpoint, @link_salt, payload)

  @doc """
  Redeems a deep-link token for the logged-in `user`, binding their account to the
  Teams identity carried in the token.

  Tenant-consistency gate: if the user already has an enterprise SSO identity, its
  org's IdP tenant must match the token's tenant — this prevents a user from one
  Entra tenant binding a Teams identity from a different tenant. Returns
  `{:ok, link}`, or `{:error, reason}` (`:tenant_mismatch`, or a `Phoenix.Token`
  failure such as `:expired` / `:invalid`).
  """
  @spec redeem_link_token(struct(), String.t()) :: {:ok, Link.t()} | {:error, atom()}
  def redeem_link_token(user, token) do
    with {:ok, %{aad_object_id: oid, tenant_id: tenant} = payload} <-
           Phoenix.Token.verify(PerfectPaperWeb.Endpoint, @link_salt, token,
             max_age: @link_max_age
           ),
         :ok <- check_tenant_consistency(user, tenant) do
      upsert_link(%{
        user_id: user.id,
        aad_object_id: oid,
        tenant_id: tenant,
        service_url: payload[:service_url],
        conversation_reference: payload[:conversation_reference] || %{}
      })
    end
  end

  # Tenant-consistency check for deep-link redemption.
  #
  # Data-ownership note: Accounts owns `user_identities`, SSO owns the per-org SSO
  # config. We therefore resolve the user's enterprise org id through Accounts
  # (`get_oidc_org_id_for_user/1`) and the org's verified IdP tenant through SSO
  # (`get_config_by_org_id/1`), rather than reaching across context boundaries. A
  # user with no enterprise identity (or whose org has no enabled+verified SSO
  # config) is unconstrained — there is no tenant to disagree with.
  @spec check_tenant_consistency(struct(), String.t()) :: :ok | {:error, :tenant_mismatch}
  defp check_tenant_consistency(user, tenant) do
    with org_id when is_binary(org_id) <- Accounts.get_oidc_org_id_for_user(user.id),
         %{oidc_tenant_id: config_tenant} when not is_nil(config_tenant) <-
           SSO.get_config_by_org_id(org_id) do
      if config_tenant == tenant, do: :ok, else: {:error, :tenant_mismatch}
    else
      _ -> :ok
    end
  end

  # ── Proactive dispatch (used by NotifierServer / NotifyWorker in Task 6) ────

  @doc """
  Sends a proactive event card to a user if they are linked and not muted.
  Returns `:ok` when a card was dispatched, or `:skip` when the user is unlinked
  or has muted notifications.
  """
  @spec notify(Ecto.UUID.t(), atom(), map()) :: :ok | :skip
  def notify(user_id, event_type, data) do
    case get_link_by_user(user_id) do
      %Link{muted: false} = link ->
        Bot.send_proactive(link.conversation_reference, Card.event(event_type, data))
        :ok

      _ ->
        :skip
    end
  end

  @doc """
  Resolves the user personally affected by a domain event and enqueues a
  proactive Teams card job via `NotifyWorker`. Skips silently when the event
  has no user-linked target, the user has no Teams link, or the link is muted.

  Called by `Teams.NotifierServer` on every subscribed event. Always returns `:ok`.
  """
  @spec enqueue_for_event(PerfectPaper.Events.Event.t()) :: :ok
  def enqueue_for_event(%PerfectPaper.Events.Event{
        id: event_id,
        type: type,
        data: data,
        actor_id: actor_id,
        organization_id: org_id
      }) do
    with {:ok, user_id, title} <- affected(type, data, actor_id),
         %Link{muted: false} = link <- get_link_by_user(user_id),
         true <- notifiable_org?(org_id, link) do
      # `event_id` is the idempotency key — the worker's `unique` dedups a
      # re-emitted/duplicate enqueue of the same event.
      %{
        "event_id" => event_id,
        "user_id" => user_id,
        "event_type" => to_string(type),
        "title" => title
      }
      |> PerfectPaper.Teams.NotifyWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  # An org-scoped event reaches a user's Teams only when the link was established
  # under that org's Azure tenant — so a user who belongs to several orgs never
  # sees one org's session activity on a Teams account they linked under a
  # different org's tenant. Personal (org-less) events carry no cross-tenant
  # exposure, so they always pass.
  defp notifiable_org?(nil, _link), do: true

  defp notifiable_org?(org_id, %Link{tenant_id: tenant_id}),
    do: match?(%{oidc_tenant_id: ^tenant_id}, SSO.get_config_by_org_id(org_id))

  # Resolves {:ok, user_id, title} for events that concern a specific user, or
  # :skip for events that don't target anyone with a Teams link.

  # session.completed: the actor (owner) who ran the review is notified.
  defp affected(:"session.completed", data, actor_id) when is_binary(actor_id),
    do: {:ok, actor_id, title_for_session(data)}

  # session.shared: the invited user is notified.
  defp affected(:"session.shared", data, _actor) do
    case data["invited_user_id"] do
      id when is_binary(id) -> {:ok, id, title_for_session(data)}
      _ -> :skip
    end
  end

  # comment.added: notify the session owner, but NOT if they wrote the comment
  # themselves (no self-notify). Skip group-owned sessions — no Teams link to send to.
  # The `comment.added` event data map is atom-keyed (emitted in-process by History),
  # so we check both atom and string key forms for defensive robustness.
  defp affected(:"comment.added", data, actor_id) do
    session_id = data[:session_id] || data["session_id"]

    case History.get_session_by_id(session_id) do
      %{owner_type: :user, owner_id: owner_id, title: title}
      when is_binary(owner_id) and owner_id != actor_id ->
        {:ok, owner_id, title || "Your manuscript"}

      _ ->
        :skip
    end
  end

  defp affected(_type, _data, _actor), do: :skip

  # Extracts a human-readable title from an event data map, falling back to a
  # safe default so no proactive card ever shows a blank title.
  # Handles both atom-keyed maps (emitted in-process by History) and string-keyed
  # maps (e.g. from tests or serialized payloads).
  @spec title_for_session(map()) :: String.t()
  defp title_for_session(%{title: t}) when is_binary(t) and t != "", do: t
  defp title_for_session(%{"title" => t}) when is_binary(t) and t != "", do: t
  defp title_for_session(_), do: "Your manuscript"
end
