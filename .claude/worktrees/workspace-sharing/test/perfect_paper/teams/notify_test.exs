defmodule PerfectPaper.Teams.NotifyTest do
  @moduledoc """
  Tests for `Teams.enqueue_for_event/1` (proactive dispatch) and
  `Teams.NotifyWorker` (Oban worker execution).
  """
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  alias PerfectPaper.{Teams, Accounts, SSO}
  alias PerfectPaper.Accounts.Scope
  alias PerfectPaper.Events.Event
  alias PerfectPaper.Teams.NotifyWorker

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  import PerfectPaper.HistoryFixtures

  # ---------------------------------------------------------------------------
  # Setup: org + SSO-linked owner + active Teams link
  # ---------------------------------------------------------------------------

  setup do
    # Make the Bot stub record sends to this test process.
    Process.put(:teams_bot_pid, self())

    owner = user_fixture()
    org = organization_fixture(owner)
    scope = Scope.for_user(owner)

    {:ok, _} =
      SSO.configure_sso(org, scope, %{
        protocol: :oidc,
        email_domain: "acme.com",
        oidc_tenant_id: "tenant-1",
        oidc_client_id: "c",
        oidc_client_secret: "s"
      })

    {:ok, _} = SSO.verify_domain(org, scope)
    {:ok, _} = SSO.enable_sso(org, scope, true)

    {:ok, _} =
      Accounts.create_identity(owner, %{
        provider: "oidc:#{org.id}",
        provider_uid: "aad-1",
        provider_email: owner.email
      })

    # Link the owner to Teams (mimics what handle_activity does on install).
    {:ok, link} =
      Teams.redeem_link_token(
        owner,
        Teams.issue_link_token(%{
          aad_object_id: "aad-1",
          tenant_id: "tenant-1",
          conversation_reference: %{
            "serviceUrl" => "https://smba/",
            "conversation" => %{"id" => "c1"}
          },
          service_url: "https://smba/"
        })
      )

    %{owner: owner, org: org, link: link}
  end

  # ---------------------------------------------------------------------------
  # enqueue_for_event/1 — session.completed
  # ---------------------------------------------------------------------------

  describe "enqueue_for_event/1 with session.completed" do
    test "enqueues a NotifyWorker job for the actor (session owner)", %{owner: owner} do
      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.completed",
        occurred_at: DateTime.utc_now(),
        actor_id: owner.id,
        data: %{"title" => "My Draft"}
      }

      assert :ok = Teams.enqueue_for_event(event)

      assert_enqueued(
        worker: NotifyWorker,
        args: %{"user_id" => owner.id, "event_type" => "session.completed", "title" => "My Draft"}
      )
    end

    test "falls back to 'Your manuscript' when title is absent", %{owner: owner} do
      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.completed",
        occurred_at: DateTime.utc_now(),
        actor_id: owner.id,
        data: %{}
      }

      assert :ok = Teams.enqueue_for_event(event)

      assert_enqueued(
        worker: NotifyWorker,
        args: %{"user_id" => owner.id, "title" => "Your manuscript"}
      )
    end

    test "does NOT enqueue when the link is muted", %{owner: owner, link: link} do
      # Mute the link via the mute changeset directly.
      {:ok, _} = PerfectPaper.Repo.update(PerfectPaper.Teams.Link.mute_changeset(link, true))

      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.completed",
        occurred_at: DateTime.utc_now(),
        actor_id: owner.id,
        data: %{"title" => "Muted Doc"}
      }

      assert :ok = Teams.enqueue_for_event(event)

      refute_enqueued(worker: NotifyWorker, args: %{"user_id" => owner.id})
    end

    test "does NOT enqueue when the user has no Teams link" do
      other_user = user_fixture()

      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.completed",
        occurred_at: DateTime.utc_now(),
        actor_id: other_user.id,
        data: %{"title" => "No Link"}
      }

      assert :ok = Teams.enqueue_for_event(event)

      refute_enqueued(worker: NotifyWorker, args: %{"user_id" => other_user.id})
    end
  end

  # ---------------------------------------------------------------------------
  # enqueue_for_event/1 — cross-org tenant scoping
  # ---------------------------------------------------------------------------

  describe "enqueue_for_event/1 org/tenant scoping" do
    test "enqueues an org-scoped event whose tenant matches the link's tenant", %{
      owner: owner,
      org: org
    } do
      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.completed",
        occurred_at: DateTime.utc_now(),
        actor_id: owner.id,
        organization_id: org.id,
        data: %{"title" => "Same-tenant Draft"}
      }

      assert :ok = Teams.enqueue_for_event(event)

      assert_enqueued(
        worker: NotifyWorker,
        args: %{"user_id" => owner.id, "title" => "Same-tenant Draft"}
      )
    end

    test "does NOT enqueue an event from a DIFFERENT org/tenant than the link's", %{owner: owner} do
      # A second org under a different Azure tenant. The owner is linked under
      # tenant-1, so a session from this org must not reach their Teams.
      other_admin = user_fixture()
      other_org = organization_fixture(other_admin)
      other_scope = Scope.for_user(other_admin)

      {:ok, _} =
        SSO.configure_sso(other_org, other_scope, %{
          protocol: :oidc,
          email_domain: "beta.com",
          oidc_tenant_id: "tenant-2",
          oidc_client_id: "c",
          oidc_client_secret: "s"
        })

      {:ok, _} = SSO.verify_domain(other_org, other_scope)
      {:ok, _} = SSO.enable_sso(other_org, other_scope, true)

      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.completed",
        occurred_at: DateTime.utc_now(),
        actor_id: owner.id,
        organization_id: other_org.id,
        data: %{"title" => "Cross-tenant Draft"}
      }

      assert :ok = Teams.enqueue_for_event(event)
      refute_enqueued(worker: NotifyWorker, args: %{"user_id" => owner.id})
    end
  end

  # ---------------------------------------------------------------------------
  # enqueue_for_event/1 — comment.added (no-self-notify)
  # ---------------------------------------------------------------------------

  describe "enqueue_for_event/1 with comment.added" do
    test "enqueues for the session owner when a different user comments", %{
      owner: owner,
      org: _org
    } do
      # Create a session owned by `owner`.
      session = session_fixture(%{user: owner, title: "Annotated Paper"})

      # `commenter` is the actor — different from the session owner.
      commenter = user_fixture()

      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"comment.added",
        occurred_at: DateTime.utc_now(),
        actor_id: commenter.id,
        data: %{session_id: session.id}
      }

      assert :ok = Teams.enqueue_for_event(event)

      assert_enqueued(
        worker: NotifyWorker,
        args: %{"user_id" => owner.id, "event_type" => "comment.added"}
      )
    end

    test "does NOT enqueue when the session owner comments on their own session",
         %{owner: owner} do
      session = session_fixture(%{user: owner, title: "Self-Comment Paper"})

      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"comment.added",
        occurred_at: DateTime.utc_now(),
        # actor == owner → self-notify suppressed
        actor_id: owner.id,
        data: %{session_id: session.id}
      }

      assert :ok = Teams.enqueue_for_event(event)

      refute_enqueued(worker: NotifyWorker, args: %{"user_id" => owner.id})
    end

    test "skips group-owned sessions (no Teams link target)", %{owner: _owner} do
      # Group-owned sessions have owner_type: :group; the affected/3 clause skips them.
      # We build a group-owned session directly to exercise this path.
      org_owner = user_fixture()
      org = organization_fixture(org_owner)

      {:ok, group} =
        PerfectPaper.Organizations.create_group(org, %{name: "Research", path: "/research"})

      session = session_fixture(%{group: group, title: "Group Paper"})

      commenter = user_fixture()

      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"comment.added",
        occurred_at: DateTime.utc_now(),
        actor_id: commenter.id,
        data: %{session_id: session.id}
      }

      assert :ok = Teams.enqueue_for_event(event)

      # No job should be enqueued for the group owner id (a group, not a user).
      refute_enqueued(worker: NotifyWorker, args: %{"event_type" => "comment.added"})
    end
  end

  # ---------------------------------------------------------------------------
  # enqueue_for_event/1 — session.shared
  # ---------------------------------------------------------------------------

  describe "enqueue_for_event/1 with session.shared" do
    test "enqueues for the invited user when they have a Teams link", %{owner: owner} do
      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.shared",
        occurred_at: DateTime.utc_now(),
        actor_id: user_fixture().id,
        data: %{"invited_user_id" => owner.id, "title" => "Shared Paper"}
      }

      assert :ok = Teams.enqueue_for_event(event)

      assert_enqueued(
        worker: NotifyWorker,
        args: %{
          "user_id" => owner.id,
          "event_type" => "session.shared",
          "title" => "Shared Paper"
        }
      )
    end

    test "skips when invited_user_id is missing from event data", %{owner: _owner} do
      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.shared",
        occurred_at: DateTime.utc_now(),
        actor_id: user_fixture().id,
        data: %{}
      }

      assert :ok = Teams.enqueue_for_event(event)

      refute_enqueued(worker: NotifyWorker, args: %{"event_type" => "session.shared"})
    end
  end

  # ---------------------------------------------------------------------------
  # NotifyWorker execution (drain_queue)
  # ---------------------------------------------------------------------------

  describe "NotifyWorker.perform/1" do
    test "draining the queue calls Teams.notify and sends a proactive card", %{owner: owner} do
      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.completed",
        occurred_at: DateTime.utc_now(),
        actor_id: owner.id,
        data: %{"title" => "Ready!"}
      }

      assert :ok = Teams.enqueue_for_event(event)

      assert_enqueued(worker: NotifyWorker, args: %{"user_id" => owner.id})

      # Drain executes the worker synchronously in the test process context.
      Oban.drain_queue(queue: :teams_notifier)

      assert_receive {:teams_proactive, _conversation_ref, _card}
    end

    test "muted link: worker skips sending (notify returns :skip)", %{owner: owner, link: link} do
      {:ok, _} = PerfectPaper.Repo.update(PerfectPaper.Teams.Link.mute_changeset(link, true))

      # Directly perform the worker (as if it were already enqueued before muting).
      result =
        perform_job(NotifyWorker, %{
          "user_id" => owner.id,
          "event_type" => "session.completed",
          "title" => "Too Late"
        })

      assert result == :ok
      # Bot stub should NOT have recorded a send.
      refute_receive {:teams_proactive, _, _}
    end
  end
end
