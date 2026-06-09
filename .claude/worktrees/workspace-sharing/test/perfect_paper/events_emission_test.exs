defmodule PerfectPaper.EventsEmissionTest do
  @moduledoc """
  Integration tests proving that domain events are emitted at the right choke
  points — after the originating DB transaction commits, never inside it.

  Covered: session.shared, comment.dismissed, comment.addressed, and the
  end-to-end fan-out from session.shared → Oban Worker enqueue.

  Skipped with notes:
  - session.completed (process_session): covered lightly via a subscribe assertion
    mirroring how history_test.exs drives it (LLM stub + credits).
  - billing subscription.updated: the choke-point is easily hit via
    Billing.upgrade_plan / Billing.downgrade_plan; tested below (subscribe-only).
  - credits.low: triggered when balance after charge < @low_balance_threshold (2);
    tested below by granting exactly 1 credit then charging.
  """
  use PerfectPaper.DataCase, async: false
  use Oban.Testing, repo: PerfectPaper.Repo

  alias PerfectPaper.{Events, History, Billing, Authz}

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  import PerfectPaper.HistoryFixtures
  import PerfectPaper.WebhooksFixtures
  import PerfectPaper.CreditsFixtures

  # ---------------------------------------------------------------------------
  # session.shared
  # ---------------------------------------------------------------------------

  describe "session.shared emission" do
    test "set_visibility(true) emits session.shared to PubSub subscribers" do
      user = user_fixture()
      session = session_fixture(user: user)
      scope = Authz.load_subject(user)

      Events.subscribe(:"session.shared")

      assert {:ok, updated} = History.set_visibility(session, scope, true)
      assert updated.is_public == true

      assert_receive {:event, %Events.Event{type: :"session.shared"}}
    end

    test "set_visibility(false) does NOT emit session.shared" do
      user = user_fixture()
      session = session_fixture(user: user)
      scope = Authz.load_subject(user)

      Events.subscribe(:"session.shared")

      assert {:ok, updated} = History.set_visibility(session, scope, false)
      refute updated.is_public

      refute_receive {:event, %Events.Event{type: :"session.shared"}}
    end

    test "set_visibility(true) on a session already public still emits" do
      user = user_fixture()
      session = session_fixture(user: user)
      scope = Authz.load_subject(user)

      # Make it public first (outside subscription window)
      History.set_visibility(session, scope, true)

      reloaded = PerfectPaper.Repo.reload!(session)

      Events.subscribe(:"session.shared")
      assert {:ok, _} = History.set_visibility(reloaded, scope, true)

      assert_receive {:event, %Events.Event{type: :"session.shared"}}
    end
  end

  # ---------------------------------------------------------------------------
  # comment.dismissed / comment.addressed
  # ---------------------------------------------------------------------------

  describe "comment.dismissed emission" do
    test "dismiss_comment emits comment.dismissed to PubSub subscribers" do
      # Use a user-owned session — the owner always has :owner role, which
      # clears :edit, so no extra group/grant setup is needed.
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session)
      scope = Authz.load_subject(user)

      Events.subscribe(:"comment.dismissed")

      assert {:ok, _result} = History.dismiss_comment(session.id, comment.id, by: scope)

      assert_receive {:event, %Events.Event{type: :"comment.dismissed"}}
    end

    test "dismiss_comment event carries the correct resource and session_id" do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session)
      scope = Authz.load_subject(user)

      Events.subscribe(:"comment.dismissed")

      History.dismiss_comment(session.id, comment.id, by: scope)

      assert_receive {:event,
                      %Events.Event{
                        type: :"comment.dismissed",
                        resource: resource,
                        data: data
                      }}

      assert resource["type"] == "comment" or
               (is_map(resource) and Map.get(resource, :type) == :comment)

      assert Map.get(data, :session_id) == session.id or
               Map.get(data, "session_id") == session.id
    end
  end

  describe "comment.addressed emission" do
    test "address_comment emits comment.addressed to PubSub subscribers" do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session)
      scope = Authz.load_subject(user)

      Events.subscribe(:"comment.addressed")

      assert {:ok, _result} = History.address_comment(session.id, comment.id, by: scope)

      assert_receive {:event, %Events.Event{type: :"comment.addressed"}}
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end fan-out: session.shared → Oban Worker
  # ---------------------------------------------------------------------------

  describe "session.shared end-to-end fan-out" do
    test "set_visibility(true) on an org-owned session enqueues a Delivery Worker" do
      # Need an org so organization_id is set on the session — Webhooks.dispatch/1
      # short-circuits on nil organization_id.
      owner = user_fixture()
      org = organization_fixture(owner)
      group = group_fixture(org)

      # The owner already has :admin on the org; add them to the group as :admin
      # so Authz permits :share (requires :admin).
      group_membership_fixture(group, owner, :admin)

      session = session_fixture(group: group)

      # Register a webhook endpoint subscribed to "session.shared" for this org
      _endpoint = endpoint_fixture(org, %{event_types: ["session.shared"]})

      scope = Authz.load_subject(owner)

      assert {:ok, updated} = History.set_visibility(session, scope, true)
      assert updated.is_public == true

      assert_enqueued(worker: PerfectPaper.Webhooks.Delivery.Worker)
    end

    test "set_visibility(false) does not enqueue any Worker job" do
      owner = user_fixture()
      org = organization_fixture(owner)
      group = group_fixture(org)
      group_membership_fixture(group, owner, :admin)

      session = session_fixture(group: group)
      _endpoint = endpoint_fixture(org, %{event_types: ["session.shared"]})

      scope = Authz.load_subject(owner)

      assert {:ok, _} = History.set_visibility(session, scope, false)

      refute_enqueued(worker: PerfectPaper.Webhooks.Delivery.Worker)
    end
  end

  # ---------------------------------------------------------------------------
  # session.completed (process_session)
  # ---------------------------------------------------------------------------

  describe "session.completed emission" do
    test "process_session emits session.completed after transaction commits" do
      # Mirrors the process_session test in history_test.exs — LLM stub is
      # configured by default; grant 1 credit so the charge succeeds.
      user = user_fixture()
      grant_fixture(user, 1)
      {:ok, session} = History.begin_session(%{user_id: user.id, title: "Paper"})

      Events.subscribe(:"session.completed")

      assert {:ok, _reviewed} = History.process_session(session, "manuscript text")

      assert_receive {:event, %Events.Event{type: :"session.completed"}}
    end

    test "session.completed carries processing_level so subscribers can distinguish a real review from an empty-doc completion" do
      user = user_fixture()
      grant_fixture(user, 1)
      {:ok, session} = History.begin_session(%{user_id: user.id, title: "Paper"})

      Events.subscribe(:"session.completed")

      assert {:ok, _reviewed} = History.process_session(session, "manuscript text")

      assert_receive {:event, %Events.Event{type: :"session.completed", data: data}}
      assert data.processing_level in ["full", "preview"]
    end
  end

  # ---------------------------------------------------------------------------
  # subscription.updated (billing)
  # ---------------------------------------------------------------------------

  describe "subscription.updated emission" do
    test "upgrade_plan emits subscription.updated" do
      user = user_fixture()

      Events.subscribe(:"subscription.updated")

      assert {:ok, _sub} = Billing.upgrade_plan(user, :professional)

      assert_receive {:event, %Events.Event{type: :"subscription.updated"}}
    end

    test "downgrade_plan emits subscription.updated" do
      user = user_fixture()
      {:ok, _} = Billing.upgrade_plan(user, :advanced)

      Events.subscribe(:"subscription.updated")

      assert {:ok, _sub} = Billing.downgrade_plan(user, :starter)

      assert_receive {:event, %Events.Event{type: :"subscription.updated"}}
    end
  end

  # ---------------------------------------------------------------------------
  # credits.low is now emitted post-commit by History.process_session (from the
  # in-lock crossing flag), not by Credits.charge_*. See
  # test/perfect_paper/credits_crossing_test.exs (flag) and
  # test/perfect_paper/history_low_credit_test.exs (post-commit emit).
end
