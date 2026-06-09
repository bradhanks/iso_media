defmodule PerfectPaper.History do
  @moduledoc """
  Proofreading history — the manuscript review sessions a writer has run, and the
  actions they take on each piece of feedback (dismiss, mark addressed, undo),
  plus sharing and viewed-state.

  This is the public API and the only `Repo` boundary for the History context.
  """
  import Ecto.Query

  alias Ecto.Multi
  alias PerfectPaper.{Repo, Credits, Chatbot, Authz, Events, Accounts, Documents}
  alias PerfectPaper.Accounts.Scope
  alias PerfectPaper.History.{Session, Comment, CommentAction}

  # ── Reading sessions ───────────────────────────────────────────────────────

  @doc "Lists the subject's visible sessions, newest first, comments preloaded."
  @spec list_sessions(Scope.t(), keyword()) :: [Session.t()]
  def list_sessions(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Session
    |> Authz.scope_query(scope, :read)
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> limit(^limit)
    |> preload(:comments)
    |> Repo.all()
  end

  @doc """
  Lists a writer's sessions, newest first, each carrying a `comments_count` but
  *without* loading the comment rows — for the index/list view, which only needs
  the count, not every comment.
  """
  @spec list_session_summaries(Scope.t(), keyword()) :: [Session.t()]
  def list_session_summaries(%Scope{} = scope, opts \\ []) do
    base =
      Session
      |> Authz.scope_query(scope, :read)
      |> maybe_filter_workspace(Keyword.get(opts, :workspace_id))
      |> order_by([s], desc: s.inserted_at, desc: s.id)
      |> limit(^Keyword.get(opts, :limit, 50))

    from(s in base,
      left_join: c in assoc(s, :comments),
      group_by: s.id,
      select: %{s | comments_count: count(c.id)}
    )
    |> Repo.all()
  end

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, ws_id) do
    # Include sessions in this workspace OR any group/org-owned session the scope
    # already authorized (scope_query runs first and gates visibility).
    where(query, [s], s.workspace_id == ^ws_id or s.owner_type == :group)
  end

  @doc """
  Fetches one session the subject may read, with comments preloaded, or `nil`.
  A session the subject can't see is indistinguishable from a missing one (404).
  """
  @spec get_session(Ecto.UUID.t(), Scope.t()) :: Session.t() | nil
  def get_session(id, %Scope{} = scope) do
    if PerfectPaper.UUID.valid?(id) do
      do_get_session(id, scope)
    else
      nil
    end
  end

  defp do_get_session(id, scope) do
    Session
    |> Authz.scope_query(scope, :read)
    |> where([s], s.id == ^id)
    |> preload(:comments)
    |> Repo.one()
  end

  @doc """
  Fetches a session by id without any authorization scope check.

  Intended for internal platform use (e.g., the Teams notifier resolving a
  session owner for an event payload). Do NOT use this from the web layer —
  use `get_session/2` with a `Scope` there.
  """
  @spec get_session_by_id(Ecto.UUID.t()) :: Session.t() | nil
  def get_session_by_id(id), do: Repo.get(Session, id)

  # ── Running a session ──────────────────────────────────────────────────────

  @doc "Begins a proofreading session for an uploaded manuscript."
  @spec begin_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def begin_session(attrs) do
    attrs = with_user_owner(Map.new(attrs))
    %Session{} |> Session.create_changeset(attrs) |> Repo.insert()
  end

  # A session created from a bare user_id is user-owned. Group-owned sessions
  # pass owner_type/owner_id (+ owner_path/organization_id) explicitly.
  defp with_user_owner(%{user_id: user_id} = attrs) when not is_nil(user_id) do
    attrs
    |> Map.put_new(:owner_type, :user)
    |> Map.put_new(:owner_id, user_id)
  end

  defp with_user_owner(attrs), do: attrs

  @doc "Finishes a session: stores overall feedback and marks it complete."
  @spec finish_session(Session.t(), map()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def finish_session(%Session{} = session, attrs) do
    session |> Session.complete_changeset(attrs) |> Repo.update()
  end

  @doc """
  Runs the review for a pending session against the given manuscript text and
  completes it.

  The processing level is set by entitlement: a writer with a paid credit gets a
  `:full` agentic review, a writer with only a preview credit gets a `:preview`
  (a lighter pass); with neither, nothing runs (`{:error, :no_credits}`).

  The credit is charged **only after** the review succeeds, inside the same
  transaction that persists the comments — so a failed LLM call never consumes a
  credit, and a failed persist never leaves a charge behind. Returns the reloaded
  session.
  """
  @spec process_session(Session.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  # Idempotency guard: never re-charge or re-run a paid review on an
  # already-complete session (a re-enqueued ReviewWorker, e.g. after a Conversion
  # retry, would otherwise burn a second credit + a second paid LLM call).
  def process_session(%Session{processing_status: :complete} = session, _document_text),
    do: {:ok, session}

  def process_session(%Session{} = session, document_text) when is_binary(document_text) do
    if String.trim(document_text) == "" do
      complete_without_review(session)
    else
      review_and_complete(session, document_text)
    end
  end

  defp review_and_complete(session, document_text) do
    with {:ok, level} <- level_for_session(session),
         {:ok, review} <-
           Chatbot.review_document(document_text, level, %{
             org_id: session.organization_id,
             owner_type: session.owner_type,
             owner_id: session.owner_id,
             locale: owner_locale(session)
           }) do
      Multi.new()
      |> Multi.run(:charge, fn _repo, _changes -> charge_for_level(session, level) end)
      |> Multi.update(
        :session,
        Session.complete_changeset(session, %{
          overall_feedback: review.overall_feedback,
          processing_level: level
        })
      )
      |> insert_comments(anchor_comments(review.comments, session), session.id)
      |> Repo.transaction()
      |> case do
        {:ok, %{charge: charge}} ->
          reloaded = Repo.get(Session, session.id) |> Repo.preload(:comments)
          emit_session_completed(reloaded)
          maybe_emit_low_credit(charge)
          {:ok, reloaded}

        {:error, :charge, :insufficient_credits, _} ->
          {:error, :no_credits}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # A structurally-valid manuscript can still flatten to no reviewable text
  # (image-only, divider-only, whitespace). Complete the session with a clear
  # note rather than pay for an LLM call / burn a credit on empty input.
  @empty_document_feedback "No reviewable text was found in this document."
  defp complete_without_review(session) do
    session
    |> Session.complete_changeset(%{overall_feedback: @empty_document_feedback})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        reloaded = Repo.preload(updated, :comments)
        emit_session_completed(reloaded)
        {:ok, reloaded}

      {:error, _} = error ->
        error
    end
  end

  defp emit_session_completed(session) do
    _ =
      Events.emit(:"session.completed", %{
        organization_id: session.organization_id,
        actor_id: session.owner_id,
        resource: %{type: :session, id: session.id},
        data: %{
          title: session.title,
          processing_status: "complete",
          # nil for an empty-doc completion (no review ran); lets subscribers
          # distinguish a billed review from a no-text auto-complete.
          processing_level: session.processing_level && Atom.to_string(session.processing_level)
        }
      })

    :ok
  end

  # The affordable review level for the session's payer. User-owned sessions draw
  # the owner's personal credits; group-owned sessions draw the org pool (the same
  # pool charge_for_level/2 charges). Gating a group on owner_id's personal balance
  # would always read 0 — owner_id is the GROUP id — and wrongly deny org-funded
  # reviews. charge_pool/2 remains the authoritative atomic gate at charge time.
  defp level_for_session(%Session{owner_type: :group, organization_id: org_id})
       when is_binary(org_id) do
    if PerfectPaper.Organizations.pool_affordable?(org_id, 1),
      do: {:ok, :full},
      else: {:error, :no_credits}
  end

  defp level_for_session(%Session{owner_id: user_id}), do: intended_level(user_id)

  # Anchor each comment back onto the document by reverse-mapping its quoted
  # `original_text` to a canonical node + UTF-16 offsets, so the workspace can
  # highlight the passage. Comments whose text spans/misses nodes (or sessions
  # with no converted document) keep nil anchors and simply don't highlight.
  defp anchor_comments(comments, session) do
    case anchor_doc(session) do
      nil -> comments
      doc -> Enum.map(comments, &add_anchor(&1, doc))
    end
  end

  defp anchor_doc(%Session{document_id: nil}), do: nil

  defp anchor_doc(%Session{document_id: id}) do
    case Documents.get_document(id) do
      nil -> nil
      document -> Documents.canonical_doc(document)
    end
  end

  defp add_anchor(comment, doc) do
    case Documents.anchor_for_text(doc, comment[:original_text]) do
      %{} = anchor -> Map.merge(comment, anchor)
      nil -> comment
    end
  end

  defp insert_comments(multi, comments, session_id) do
    comments
    |> Enum.with_index(1)
    |> Enum.reduce(multi, fn {attrs, idx}, acc ->
      changeset =
        Comment.create_changeset(
          %Comment{},
          attrs |> Map.put(:session_id, session_id) |> Map.put_new(:position, idx)
        )

      Multi.insert(acc, {:comment, idx}, changeset)
    end)
  end

  @doc "Best-effort entitlement: the review level the user can afford right now."
  @spec intended_level(Ecto.UUID.t()) :: {:ok, :full | :preview} | {:error, :no_credits}
  def intended_level(user_id) do
    cond do
      Credits.balance(user_id, :paid) >= 1 -> {:ok, :full}
      Credits.balance(user_id, :preview) >= 1 -> {:ok, :preview}
      true -> {:error, :no_credits}
    end
  end

  @doc "All sessions whose source document is `document_id`."
  @spec sessions_for_document(Ecto.UUID.t()) :: [Session.t()]
  def sessions_for_document(document_id) do
    from(s in Session, where: s.document_id == ^document_id) |> Repo.all()
  end

  @doc "Enqueues an idempotent async review for a session (see History.ReviewWorker)."
  @spec enqueue_review(Session.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_review(%Session{id: id}) do
    %{session_id: id} |> PerfectPaper.History.ReviewWorker.new() |> Oban.insert()
  end

  # Charge the bucket the level draws from. Returns the Multi.run-friendly
  # {:ok, _} | {:error, :insufficient_credits}; the charge itself re-checks the
  # balance atomically, so a credit spent concurrently still fails cleanly.
  # Org-owned (group) sessions draw the organization's pool; personal (user)
  # sessions draw the owner's personal credits. Returns the Multi.run-friendly
  # {:ok, _} | {:error, :insufficient_*}.
  defp charge_for_level(%{owner_type: :group, organization_id: org_id}, _level)
       when is_binary(org_id) do
    with :ok <- PerfectPaper.Organizations.charge_pool(org_id, 1) do
      {:ok, %{crossed_low?: false, user_id: nil}}
    end
  end

  defp charge_for_level(%{owner_id: user_id}, :full) do
    with {:ok, _event, crossed?} <- Credits.charge_for_proofreading(user_id) do
      {:ok, %{crossed_low?: crossed?, user_id: user_id}}
    end
  end

  defp charge_for_level(%{owner_id: user_id}, :preview) do
    with {:ok, _event, crossed?} <- Credits.charge_for_preview(user_id) do
      {:ok, %{crossed_low?: crossed?, user_id: user_id}}
    end
  end

  # Post-commit: a personal charge that crossed the low-credit threshold fans out
  # the already-registered :"credits.low" event (subscribers: the upsell-email
  # Oban worker). Group charges (user_id: nil) never fire. Emitting here — after
  # Repo.transaction returns {:ok, _} — honors the events.ex "never before commit"
  # rule and makes a rolled-back review fire nothing.
  defp maybe_emit_low_credit(%{crossed_low?: true, user_id: user_id}) when is_binary(user_id) do
    user = Accounts.get_user!(user_id)
    sub = PerfectPaper.Billing.get_subscription_for_user(user_id)
    threshold = Credits.effective_low_credit_threshold(user, sub)
    balance = Credits.balance(user_id)
    billing_period = (sub && sub.billing_period) || :monthly

    :telemetry.execute(
      [:perfect_paper, :credits, :low_balance_alert],
      %{balance: balance, threshold: threshold},
      %{annual?: billing_period == :annual}
    )

    _ =
      Events.emit(:"credits.low", %{
        organization_id: nil,
        actor_id: user_id,
        resource: %{type: :user, id: user_id},
        data: %{
          balance: balance,
          threshold: threshold,
          billing_period: billing_period,
          crossing_id: "#{user_id}:#{System.unique_integer([:monotonic, :positive])}"
        }
      })

    :ok
  end

  defp maybe_emit_low_credit(_charge), do: :ok

  # The language the AI review should be written in: the owner's locale for a
  # user-owned session, English for group-owned (no single reader's language).
  defp owner_locale(%Session{owner_type: :user, owner_id: user_id}),
    do: Accounts.get_user_locale(user_id)

  defp owner_locale(_session), do: "en"

  @doc "Permanently deletes a session and all its feedback (requires :delete)."
  @spec delete_session(Session.t(), Scope.t()) :: {:ok, Session.t()} | {:error, term()}
  def delete_session(%Session{} = session, %Scope{} = scope) do
    with :ok <- Authz.permit?(scope, :delete, session) do
      Repo.delete(session)
    end
  end

  # ── Adding human comments ──────────────────────────────────────────────────

  @doc """
  Adds a human comment to a session (requires `:comment`). `attrs` may include
  `:body` (required) and `:parent_id` (a reply target in the SAME session).
  Emits `comment.added` post-commit.
  """
  @spec add_comment(Ecto.UUID.t(), Scope.t(), map()) :: {:ok, Comment.t()} | {:error, term()}
  def add_comment(session_id, %Scope{} = scope, attrs) do
    attrs = Map.new(attrs)
    parent_id = attrs[:parent_id] || attrs["parent_id"]

    with %Session{} = session <- Repo.get(Session, session_id),
         :ok <- Authz.permit?(scope, :comment, session),
         :ok <- validate_parent(parent_id, session_id),
         {:ok, comment} <-
           %Comment{}
           |> Comment.author_changeset(%{
             session_id: session_id,
             author_id: scope.user.id,
             body: attrs[:body] || attrs["body"],
             parent_id: parent_id
           })
           |> Repo.insert() do
      _ =
        Events.emit(:"comment.added", %{
          organization_id: session.organization_id,
          actor_id: scope.user.id,
          resource: %{type: :comment, id: comment.id},
          data: %{session_id: session_id, parent_id: comment.parent_id}
        })

      {:ok, comment}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Acting on comments ─────────────────────────────────────────────────────

  @doc "Marks a comment dismissed (the writer chose to ignore it)."
  @spec dismiss_comment(Ecto.UUID.t(), Ecto.UUID.t(), [{:by, Scope.t()}]) ::
          {:ok, map()} | {:error, term()}
  def dismiss_comment(session_id, comment_id, by: %Scope{} = scope),
    do: act_on_comment(session_id, comment_id, scope, :dismiss)

  @doc "Marks a comment addressed (the writer applied the suggestion)."
  @spec address_comment(Ecto.UUID.t(), Ecto.UUID.t(), [{:by, Scope.t()}]) ::
          {:ok, map()} | {:error, term()}
  def address_comment(session_id, comment_id, by: %Scope{} = scope),
    do: act_on_comment(session_id, comment_id, scope, :address)

  @doc "Undoes a dismiss/address, reverting the comment to open."
  @spec undo_comment_action(Ecto.UUID.t(), Ecto.UUID.t(), Scope.t(), Comment.action()) ::
          {:ok, map()} | {:error, term()}
  def undo_comment_action(session_id, comment_id, %Scope{} = scope, action_type) do
    with %Session{} = session <- Repo.get(Session, session_id),
         :ok <- Authz.permit?(scope, :edit, session),
         %Comment{} = comment <- Repo.get(Comment, comment_id),
         :ok <- guard_undo_action(comment, action_type),
         action when not is_nil(action) <-
           Repo.one(
             from a in CommentAction,
               where:
                 a.session_id == ^session_id and a.comment_id == ^comment_id and
                   a.action_type == ^action_type
           ) do
      Ecto.Multi.new()
      |> Ecto.Multi.delete(:action, action)
      |> Ecto.Multi.update(:comment, Comment.undo_action_changeset(comment, action_type))
      |> Repo.transaction()
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Sharing & viewed-state ─────────────────────────────────────────────────

  @doc "Makes a session shareable (public) or private (requires :share)."
  @spec set_visibility(Session.t(), Scope.t(), boolean()) ::
          {:ok, Session.t()} | {:error, term()}
  def set_visibility(%Session{} = session, %Scope{} = scope, is_public)
      when is_boolean(is_public) do
    with :ok <- Authz.permit?(scope, :share, session),
         {:ok, updated} <-
           session |> Session.flags_changeset(%{is_public: is_public}) |> Repo.update() do
      if updated.is_public do
        _ =
          Events.emit(:"session.shared", %{
            organization_id: updated.organization_id,
            actor_id: scope.user.id,
            resource: %{type: :session, id: updated.id},
            data: %{is_public: true}
          })
      end

      {:ok, updated}
    end
  end

  @doc "Renames a session's manuscript title (requires `:edit`)."
  @spec rename_session(Session.t(), Scope.t(), String.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def rename_session(%Session{} = session, %Scope{} = scope, title) when is_binary(title) do
    with :ok <- Authz.permit?(scope, :edit, session),
         {:ok, updated} <-
           session |> Session.title_changeset(%{title: title}) |> Repo.update() do
      {:ok, updated}
    end
  end

  @doc """
  Invites a recipient to collaborate on a session (default `:commenter`).
  Requires `:share`. `recipient` may be an email string (the user is found or
  created as a magic-link guest and an invite email is dispatched) or an
  existing `%User{}` / user-shaped map (no email is sent). Emits
  `session.shared` on success.
  """
  @spec invite_to_session(Session.t(), Scope.t(), String.t() | map(), Authz.Role.t()) ::
          {:ok, %{user: map(), grant: map()}} | {:error, term()}
  def invite_to_session(%Session{} = session, %Scope{} = scope, recipient, role \\ :commenter) do
    with :ok <- Authz.permit?(scope, :share, session),
         {:ok, user, guest?} <- resolve_recipient(recipient),
         {:ok, grant} <- Authz.grant_access(scope, {:session, session.id}, {:user, user.id}, role) do
      if guest?, do: deliver_session_invite(user, session)

      _ =
        Events.emit(:"session.shared", %{
          organization_id: session.organization_id,
          actor_id: scope.user.id,
          resource: %{type: :session, id: session.id},
          data: %{invited_user_id: user.id}
        })

      {:ok, %{user: user, grant: grant}}
    end
  end

  defp resolve_recipient(%{id: _id} = user), do: {:ok, user, false}

  defp resolve_recipient(email) when is_binary(email) do
    case Accounts.find_or_create_guest(email) do
      {:ok, user} -> {:ok, user, true}
      {:error, _} = err -> err
    end
  end

  defp deliver_session_invite(user, session) do
    Accounts.deliver_login_instructions(user, fn token ->
      redirect_to = "/history/#{session.id}"

      PerfectPaperWeb.Endpoint.url() <>
        "/users/log-in/#{token}?redirect_to=#{URI.encode_www_form(redirect_to)}"
    end)
  end

  @doc "Marks a session as seen by its owner (clears the unread indicator)."
  @spec mark_viewed(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def mark_viewed(%Session{} = session),
    do: session |> Session.flags_changeset(%{viewed: true}) |> Repo.update()

  @doc "Moves every review in `from_workspace_id` to `to_workspace_id`. Returns {:ok, count}."
  @spec reassign_reviews(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def reassign_reviews(from_workspace_id, to_workspace_id) do
    {count, _} =
      from(s in Session, where: s.workspace_id == ^from_workspace_id)
      |> Repo.update_all(set: [workspace_id: to_workspace_id])

    {:ok, count}
  end

  # Acting on a comment is an :edit-level action on the session. Authorize via
  # Authz (not_found hides existence; unauthorized = visible but under-roled),
  # then record the action + move the comment in one transaction.
  defp act_on_comment(session_id, comment_id, %Scope{} = scope, action_type) do
    with %Session{} = session <- Repo.get(Session, session_id),
         :ok <- Authz.permit?(scope, :edit, session),
         %Comment{} = comment <-
           Repo.one(from c in Comment, where: c.id == ^comment_id and c.session_id == ^session_id),
         :ok <- guard_comment_action(comment, action_type) do
      attrs = %{
        session_id: session_id,
        comment_id: comment_id,
        user_id: scope.user.id,
        action_type: action_type
      }

      result =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:action, CommentAction.create_changeset(%CommentAction{}, attrs))
        |> Ecto.Multi.update(:comment, Comment.apply_action_changeset(comment, action_type))
        |> Repo.transaction()

      with {:ok, _changes} <- result do
        event_type = comment_action_event(action_type)

        _ =
          Events.emit(event_type, %{
            organization_id: session.organization_id,
            actor_id: scope.user.id,
            resource: %{type: :comment, id: comment_id},
            data: %{session_id: session_id}
          })
      end

      result
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp comment_action_event(:dismiss), do: :"comment.dismissed"
  defp comment_action_event(:address), do: :"comment.addressed"

  # Guard: only allow acting on a comment that is currently :open.
  # If already in the target state → idempotent :already_done.
  # If in a different non-open state → :invalid_transition.
  defp guard_comment_action(%Comment{status: :open}, _action_type), do: :ok
  defp guard_comment_action(%Comment{status: :dismissed}, :dismiss), do: {:error, :already_done}
  defp guard_comment_action(%Comment{status: :addressed}, :address), do: {:error, :already_done}
  defp guard_comment_action(%Comment{}, _action_type), do: {:error, :invalid_transition}

  # Guard: undo is only valid when the comment's current status matches the action.
  defp guard_undo_action(%Comment{status: :dismissed}, :dismiss), do: :ok
  defp guard_undo_action(%Comment{status: :addressed}, :address), do: :ok
  defp guard_undo_action(%Comment{}, _action_type), do: {:error, :invalid_transition}

  defp validate_parent(nil, _session_id), do: :ok

  defp validate_parent(parent_id, session_id) do
    case Repo.one(
           from c in Comment, where: c.id == ^parent_id and c.session_id == ^session_id, select: 1
         ) do
      nil -> {:error, :invalid_parent}
      _ -> :ok
    end
  end
end
