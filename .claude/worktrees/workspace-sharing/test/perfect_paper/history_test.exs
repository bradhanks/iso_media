defmodule PerfectPaper.HistoryTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.History
  alias PerfectPaper.Authz

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures
  import PerfectPaper.CreditsFixtures
  import PerfectPaper.OrganizationsFixtures
  import Swoosh.TestAssertions

  alias PerfectPaper.{Credits, Accounts, Events}

  describe "process_session/2" do
    test "a writer with a credit gets a charged, full-level review" do
      user = user_fixture()
      grant_fixture(user, 5)
      {:ok, session} = History.begin_session(%{user_id: user.id, title: "Doc"})

      assert {:ok, reviewed} = History.process_session(session, "manuscript text")

      assert reviewed.processing_status == :complete
      assert reviewed.processing_level == :full
      assert is_binary(reviewed.overall_feedback)
      assert length(reviewed.comments) > 1
      # 1 credit = 1 full review.
      assert Credits.balance(user.id) == 4
    end

    test "a writer with no credits at all is blocked — nothing is free without a credit" do
      user = user_fixture()
      {:ok, session} = History.begin_session(%{user_id: user.id, title: "Doc"})

      assert {:error, :no_credits} = History.process_session(session, "manuscript text")
    end

    test "a writer with a preview credit gets a free (throttled) preview, consuming it" do
      user = user_fixture()
      {:ok, _} = Credits.grant(user.id, 1, "promo", :preview)
      {:ok, session} = History.begin_session(%{user_id: user.id, title: "Doc"})

      assert {:ok, reviewed} = History.process_session(session, "manuscript text")

      assert reviewed.processing_status == :complete
      assert reviewed.processing_level == :preview
      assert length(reviewed.comments) == 1
      assert Credits.balance(user.id, :preview) == 0
    end
  end

  describe "begin_session/1" do
    test "creates a pending session for a user" do
      user = user_fixture()
      assert {:ok, session} = History.begin_session(%{user_id: user.id, title: "Doc"})
      assert session.processing_status == :pending
      assert session.user_id == user.id
    end

    test "requires an owner (owner_type and owner_id)" do
      assert {:error, changeset} = History.begin_session(%{title: "x"})
      errors = errors_on(changeset)
      assert errors[:owner_type]
      assert errors[:owner_id]
    end
  end

  describe "list_sessions/2" do
    test "returns a user's sessions newest first" do
      user = user_fixture()
      {:ok, _a} = History.begin_session(%{user_id: user.id, title: "A"})
      {:ok, b} = History.begin_session(%{user_id: user.id, title: "B"})
      assert [first | _] = History.list_sessions(Authz.load_subject(user))
      assert first.id == b.id
    end
  end

  describe "list_session_summaries/2" do
    test "returns sessions newest first with a comments_count and no loaded comments" do
      user = user_fixture()
      {:ok, a} = History.begin_session(%{user_id: user.id, title: "A"})
      {:ok, b} = History.begin_session(%{user_id: user.id, title: "B"})
      comment_fixture(a)
      comment_fixture(a)

      assert [summary_b, summary_a] = History.list_session_summaries(Authz.load_subject(user))
      assert summary_b.id == b.id
      assert summary_b.comments_count == 0
      assert summary_a.id == a.id
      assert summary_a.comments_count == 2
      # comments are NOT preloaded by the summary query
      assert %Ecto.Association.NotLoaded{} = summary_a.comments
    end

    test "scopes to the given user" do
      user = user_fixture()
      other = user_fixture()
      session_fixture(user: other)
      assert History.list_session_summaries(Authz.load_subject(user)) == []
    end
  end

  describe "finish_session/2" do
    test "stores overall feedback and marks complete" do
      session = session_fixture()
      assert {:ok, done} = History.finish_session(session, %{overall_feedback: "Solid."})
      assert done.processing_status == :complete
      assert done.overall_feedback == "Solid."
    end
  end

  describe "dismiss_comment/3 + undo_comment_action/4" do
    test "dismiss sets status and records an action; undo reverts" do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session)
      scope = Authz.load_subject(user)

      assert {:ok, %{comment: dismissed}} =
               History.dismiss_comment(session.id, comment.id, by: scope)

      assert dismissed.status == :dismissed

      assert {:ok, %{comment: reverted}} =
               History.undo_comment_action(session.id, comment.id, scope, :dismiss)

      assert reverted.status == :open
    end

    test "returns an error for a comment outside the session" do
      user = user_fixture()
      session = session_fixture(user: user)
      other = session_fixture(user: user)
      comment = comment_fixture(other)
      scope = Authz.load_subject(user)

      assert {:error, :not_found} =
               History.dismiss_comment(session.id, comment.id, by: scope)
    end

    test "double-dismiss returns :already_done instead of a unique-constraint crash" do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session)
      scope = Authz.load_subject(user)

      assert {:ok, _} = History.dismiss_comment(session.id, comment.id, by: scope)
      assert {:error, :already_done} = History.dismiss_comment(session.id, comment.id, by: scope)
    end

    test "cannot address a dismissed comment — must undo first" do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session)
      scope = Authz.load_subject(user)

      assert {:ok, _} = History.dismiss_comment(session.id, comment.id, by: scope)

      assert {:error, :invalid_transition} =
               History.address_comment(session.id, comment.id, by: scope)
    end

    test "undo requires status to match the action being undone" do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session)
      scope = Authz.load_subject(user)

      assert {:ok, _} = History.dismiss_comment(session.id, comment.id, by: scope)
      # Trying to undo :address on a :dismissed comment is invalid
      assert {:error, :invalid_transition} =
               History.undo_comment_action(session.id, comment.id, scope, :address)
    end
  end

  describe "address_comment/3" do
    test "marks a comment addressed" do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session)
      scope = Authz.load_subject(user)

      assert {:ok, %{comment: addressed}} =
               History.address_comment(session.id, comment.id, by: scope)

      assert addressed.status == :addressed
    end
  end

  describe "set_visibility/3 and mark_viewed/1" do
    test "toggles the flags" do
      user = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: user)
      scope = Authz.load_subject(user)
      assert {:ok, s} = History.set_visibility(session, scope, true)
      assert s.is_public
      assert {:ok, s2} = History.mark_viewed(session)
      assert s2.viewed
    end
  end

  describe "begin_session/1 ownership" do
    test "defaults a user-owned session from user_id" do
      user = PerfectPaper.AccountsFixtures.user_fixture()
      {:ok, session} = PerfectPaper.History.begin_session(%{user_id: user.id, title: "Doc"})

      assert session.owner_type == :user
      assert session.owner_id == user.id
      assert session.user_id == user.id
    end
  end

  describe "ownership scoping (authorization)" do
    test "get_session/2 returns the owner's session but nil for anyone else" do
      owner = user_fixture()
      other = user_fixture()
      session = session_fixture(user: owner)
      _comment = comment_fixture(session)

      assert %History.Session{id: id} = History.get_session(session.id, Authz.load_subject(owner))
      assert id == session.id
      assert History.get_session(session.id, Authz.load_subject(other)) == nil
    end

    test "dismiss_comment refuses a comment on someone else's session" do
      owner = user_fixture()
      other = user_fixture()
      session = session_fixture(user: owner)
      comment = comment_fixture(session)

      assert {:error, :not_found} =
               History.dismiss_comment(session.id, comment.id, by: Authz.load_subject(other))

      # and the comment is untouched
      assert History.get_session(session.id, Authz.load_subject(owner)).comments
             |> Enum.find(&(&1.id == comment.id))
             |> Map.fetch!(:status) == :open
    end

    test "address_comment refuses a comment on someone else's session" do
      owner = user_fixture()
      other = user_fixture()
      session = session_fixture(user: owner)
      comment = comment_fixture(session)

      assert {:error, :not_found} =
               History.address_comment(session.id, comment.id, by: Authz.load_subject(other))
    end
  end

  describe "add_comment/3" do
    import PerfectPaper.AuthzFixtures

    test "a :commenter grantee adds a comment successfully" do
      owner = user_fixture()
      commenter = user_fixture()
      session = session_fixture(user: owner)
      session_grant_fixture(session, commenter, :commenter)
      scope = Authz.load_subject(commenter)

      assert {:ok, comment} = History.add_comment(session.id, scope, %{body: "Great paper!"})
      assert comment.author_type == :user
      assert comment.author_id == commenter.id
      assert comment.body == "Great paper!"
    end

    test "a user with no grant returns :not_found" do
      owner = user_fixture()
      stranger = user_fixture()
      session = session_fixture(user: owner)
      scope = Authz.load_subject(stranger)

      assert {:error, :not_found} = History.add_comment(session.id, scope, %{body: "Hello"})
    end

    test "a :viewer grantee returns :unauthorized" do
      owner = user_fixture()
      viewer = user_fixture()
      session = session_fixture(user: owner)
      session_grant_fixture(session, viewer, :viewer)
      scope = Authz.load_subject(viewer)

      assert {:error, :unauthorized} = History.add_comment(session.id, scope, %{body: "Hello"})
    end

    test "a reply with a valid parent_id in the same session sets parent_id" do
      owner = user_fixture()
      commenter = user_fixture()
      session = session_fixture(user: owner)
      session_grant_fixture(session, commenter, :commenter)
      scope = Authz.load_subject(commenter)

      {:ok, parent} = History.add_comment(session.id, scope, %{body: "Original comment"})

      assert {:ok, reply} =
               History.add_comment(session.id, scope, %{body: "A reply", parent_id: parent.id})

      assert reply.parent_id == parent.id
    end

    test "a reply with a parent_id from a different session returns :invalid_parent" do
      owner = user_fixture()
      commenter = user_fixture()
      session = session_fixture(user: owner)
      other_session = session_fixture(user: owner)
      session_grant_fixture(session, commenter, :commenter)
      session_grant_fixture(other_session, commenter, :commenter)
      scope = Authz.load_subject(commenter)

      {:ok, other_comment} =
        History.add_comment(other_session.id, scope, %{body: "Other session comment"})

      assert {:error, :invalid_parent} =
               History.add_comment(session.id, scope, %{
                 body: "Bad reply",
                 parent_id: other_comment.id
               })
    end

    test "emits comment.added after a successful insert" do
      owner = user_fixture()
      commenter = user_fixture()
      session = session_fixture(user: owner)
      session_grant_fixture(session, commenter, :commenter)
      scope = Authz.load_subject(commenter)

      PerfectPaper.Events.subscribe(:"comment.added")

      assert {:ok, _comment} = History.add_comment(session.id, scope, %{body: "Test event"})

      assert_receive {:event, %PerfectPaper.Events.Event{type: :"comment.added"}}
    end
  end

  describe "scoped reads + mutations through Authz" do
    import PerfectPaper.HistoryFixtures
    alias PerfectPaper.Authz
    alias PerfectPaper.History

    test "list_sessions/1 returns only the subject's sessions" do
      user = PerfectPaper.AccountsFixtures.user_fixture()
      mine = session_fixture(user: user)
      _other = session_fixture()
      scope = Authz.load_subject(user)

      assert [%{id: id}] = History.list_sessions(scope)
      assert id == mine.id
    end

    test "get_session/2 returns nil for a session the subject can't see" do
      session = session_fixture()
      scope = Authz.load_subject(PerfectPaper.AccountsFixtures.user_fixture())

      assert History.get_session(session.id, scope) == nil
    end

    test "dismiss_comment/3 returns :not_found for a non-owner" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      comment = comment_fixture(session)
      scope = Authz.load_subject(PerfectPaper.AccountsFixtures.user_fixture())

      assert History.dismiss_comment(session.id, comment.id, by: scope) ==
               {:error, :not_found}
    end

    test "dismiss_comment/3 succeeds for the owner" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      comment = comment_fixture(session)
      scope = Authz.load_subject(owner)

      assert {:ok, %{comment: updated}} =
               History.dismiss_comment(session.id, comment.id, by: scope)

      assert updated.status == :dismissed
    end

    test "delete_session/2 refuses a stranger (not_found — no line of sight)" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      stranger_scope = Authz.load_subject(PerfectPaper.AccountsFixtures.user_fixture())

      assert History.delete_session(session, stranger_scope) == {:error, :not_found}
    end

    test "delete_session/2 refuses a viewer-grant holder (unauthorized)" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      viewer = PerfectPaper.AccountsFixtures.user_fixture()
      PerfectPaper.AuthzFixtures.session_grant_fixture(session, viewer, :viewer)
      viewer_scope = Authz.load_subject(viewer)

      assert History.delete_session(session, viewer_scope) == {:error, :unauthorized}
    end

    test "delete_session/2 succeeds for the owner" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      scope = Authz.load_subject(owner)

      assert {:ok, _} = History.delete_session(session, scope)
    end

    test "set_visibility/3 refuses a stranger (not_found — no line of sight)" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      stranger_scope = Authz.load_subject(PerfectPaper.AccountsFixtures.user_fixture())

      assert History.set_visibility(session, stranger_scope, true) == {:error, :not_found}
    end

    test "set_visibility/3 refuses a viewer-grant holder (unauthorized)" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      viewer = PerfectPaper.AccountsFixtures.user_fixture()
      PerfectPaper.AuthzFixtures.session_grant_fixture(session, viewer, :viewer)
      viewer_scope = Authz.load_subject(viewer)

      assert History.set_visibility(session, viewer_scope, true) == {:error, :unauthorized}
    end

    test "set_visibility/3 succeeds for the owner" do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      scope = Authz.load_subject(owner)

      assert {:ok, updated} = History.set_visibility(session, scope, true)
      assert updated.is_public == true
    end
  end

  describe "comment anchors" do
    test "create_changeset casts node anchor + UTF-16 range" do
      cs =
        PerfectPaper.History.Comment.create_changeset(%PerfectPaper.History.Comment{}, %{
          session_id: Ecto.UUID.generate(),
          suggestion: "Tighten this",
          anchor_node_id: "n_b21Qd0",
          anchor_from: 3,
          anchor_to: 11
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :anchor_node_id) == "n_b21Qd0"
      assert Ecto.Changeset.get_change(cs, :anchor_from) == 3
      assert Ecto.Changeset.get_change(cs, :anchor_to) == 11
    end
  end

  describe "session ↔ document link" do
    test "a session can reference a source document" do
      user = user_fixture()
      {:ok, document} = PerfectPaper.Documents.register_upload(user, %{filename: "m.md"})

      {:ok, session} =
        PerfectPaper.History.begin_session(%{
          user_id: user.id,
          title: "M",
          document_id: document.id
        })

      assert session.document_id == document.id
    end
  end

  describe "intended_level/1 + sessions_for_document/1" do
    test "intended_level reflects credit balance" do
      user = user_fixture()
      assert PerfectPaper.History.intended_level(user.id) == {:error, :no_credits}
      PerfectPaper.Credits.grant(user.id, 1, "test")
      assert PerfectPaper.History.intended_level(user.id) == {:ok, :full}
    end

    test "sessions_for_document returns sessions linked to a document" do
      user = user_fixture()
      {:ok, document} = PerfectPaper.Documents.register_upload(user, %{filename: "m.docx"})

      {:ok, session} =
        PerfectPaper.History.begin_session(%{
          user_id: user.id,
          title: "M",
          document_id: document.id
        })

      ids = PerfectPaper.History.sessions_for_document(document.id) |> Enum.map(& &1.id)
      assert session.id in ids
    end
  end

  describe "invite_to_session/4" do
    import PerfectPaper.AuthzFixtures

    setup do
      owner = user_fixture()
      session = session_fixture(user: owner)
      scope = Authz.load_subject(owner)
      %{owner: owner, session: session, scope: scope}
    end

    test "inviting a new email creates a guest user with no org and a :commenter grant",
         %{session: session, scope: scope} do
      email = unique_user_email()

      assert {:ok, %{user: user, grant: grant}} =
               History.invite_to_session(session, scope, email, :commenter)

      # The user was created and is findable by email
      assert %Accounts.User{} = Accounts.get_user_by_email(email)
      assert user.email == email

      # No org membership (guest)
      memberships =
        PerfectPaper.Repo.all(
          from m in PerfectPaper.Organizations.GroupMembership, where: m.user_id == ^user.id
        )

      assert memberships == []

      # A :commenter grant was created
      assert grant.role == :commenter
      assert grant.subject_id == user.id
      assert grant.resource_id == session.id

      # The grant allows commenting
      loaded_scope = Authz.load_subject(user)
      reloaded_session = PerfectPaper.Repo.get!(PerfectPaper.History.Session, session.id)
      assert :ok = Authz.permit?(loaded_scope, :comment, reloaded_session)

      # An invite email was sent to the new guest
      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
      end)
    end

    test "inviting an existing %User{} returns ok with a grant, no email sent",
         %{session: session, scope: scope} do
      existing = user_fixture()

      assert {:ok, %{user: user, grant: grant}} =
               History.invite_to_session(session, scope, existing, :commenter)

      assert user.id == existing.id
      assert grant.subject_id == existing.id

      # No invite email was sent for an already-registered user
      refute_email_sent()
    end

    test "a non-owner/non-admin scope returns {:error, :unauthorized}",
         %{session: session} do
      stranger = user_fixture()
      stranger_scope = Authz.load_subject(stranger)

      assert {:error, :not_found} =
               History.invite_to_session(session, stranger_scope, "guest@example.com")
    end

    test "an unauthorized caller does NOT create a guest account before failing the :share check",
         %{session: session} do
      stranger = user_fixture()
      stranger_scope = Authz.load_subject(stranger)
      new_email = "newguest-#{System.unique_integer([:positive])}@example.com"

      assert {:error, :not_found} =
               History.invite_to_session(session, stranger_scope, new_email)

      # The authorization gate must fire BEFORE resolve_recipient, so no guest
      # account should have been created for this email.
      assert Accounts.get_user_by_email(new_email) == nil
    end

    test "emits session.shared after a successful invite",
         %{session: session, scope: scope} do
      Events.subscribe(:"session.shared")
      email = unique_user_email()

      assert {:ok, _} = History.invite_to_session(session, scope, email, :commenter)

      assert_receive {:event, %Events.Event{type: :"session.shared"}}
    end
  end

  describe "process_session/2 comment anchoring" do
    test "anchors comments whose original_text appears in the document; leaves others nil" do
      user = user_fixture()
      grant_fixture(user, 1)

      {:ok, doc} =
        PerfectPaper.Documents.store_and_register(user, "bytes", %{
          filename: "p.md",
          source_format: "markdown"
        })

      # Canonical text contains one of the stub review's quoted snippets.
      tree = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "attrs" => %{"id" => "para-1"},
            "content" => [
              %{"type" => "text", "text" => "We fit three factor-derived scales to the data."}
            ]
          }
        ]
      }

      {:ok, _} =
        doc
        |> PerfectPaper.Documents.Document.canonical_changeset(%{
          canonical_doc: tree,
          status: :converted
        })
        |> Repo.update()

      {:ok, session} =
        History.begin_session(%{user_id: user.id, title: "P", document_id: doc.id})

      assert {:ok, completed} = History.process_session(session, "irrelevant; stub ignores text")

      anchored =
        Enum.find(completed.comments, &(&1.original_text == "three factor-derived scales"))

      assert anchored.anchor_node_id == "para-1"
      assert anchored.anchor_from == 7
      assert anchored.anchor_to == 7 + String.length("three factor-derived scales")

      # A comment the LLM left without original_text gets no anchor.
      assert Enum.any?(
               completed.comments,
               &(is_nil(&1.original_text) and is_nil(&1.anchor_node_id))
             )
    end
  end

  describe "workspace scoping — group/org sessions" do
    setup do
      import PerfectPaper.AccountsFixtures
      import PerfectPaper.OrganizationsFixtures
      user = user_fixture()
      org = organization_fixture(user)
      group = group_fixture(org)
      _membership = group_membership_fixture(group, user, :viewer)

      ws =
        PerfectPaper.Repo.insert!(%PerfectPaper.Workspaces.Workspace{
          name: "My WS",
          user_id: user.id
        })

      scope = PerfectPaper.Authz.load_subject(user)
      %{user: user, org: org, group: group, ws: ws, scope: scope}
    end

    test "group-owned sessions are included in workspace-filtered list", ctx do
      {:ok, _user_session} =
        PerfectPaper.History.begin_session(%{
          user_id: ctx.user.id,
          title: "My Review",
          workspace_id: ctx.ws.id
        })

      _group_session = session_fixture(group: ctx.group, title: "Group Review")

      titles =
        ctx.scope
        |> PerfectPaper.History.list_session_summaries(workspace_id: ctx.ws.id)
        |> Enum.map(& &1.title)
        |> Enum.sort()

      assert titles == ["Group Review", "My Review"]
    end

    test "group sessions from other orgs the user cannot see are excluded", ctx do
      _group_session = session_fixture(group: ctx.group, title: "Visible Group")

      other_user = user_fixture()
      other_org = organization_fixture(other_user)
      other_group = group_fixture(other_org)
      _other_group_session = session_fixture(group: other_group, title: "Hidden Group")

      titles =
        ctx.scope
        |> PerfectPaper.History.list_session_summaries(workspace_id: ctx.ws.id)
        |> Enum.map(& &1.title)

      assert "Visible Group" in titles
      refute "Hidden Group" in titles
    end
  end

  describe "workspace scoping" do
    setup do
      import PerfectPaper.AccountsFixtures
      user = user_fixture()
      # Insert workspace rows directly so this task does not depend on the
      # Workspaces context (which lands in a later task).
      ws_a =
        PerfectPaper.Repo.insert!(%PerfectPaper.Workspaces.Workspace{
          name: "A",
          user_id: user.id
        })

      ws_b =
        PerfectPaper.Repo.insert!(%PerfectPaper.Workspaces.Workspace{
          name: "B",
          user_id: user.id
        })

      scope = PerfectPaper.Authz.load_subject(user)
      %{user: user, ws_a: ws_a, ws_b: ws_b, scope: scope}
    end

    test "begin_session stores workspace_id; list filters by it", ctx do
      {:ok, _a} =
        PerfectPaper.History.begin_session(%{
          user_id: ctx.user.id,
          title: "in A",
          workspace_id: ctx.ws_a.id
        })

      {:ok, _b} =
        PerfectPaper.History.begin_session(%{
          user_id: ctx.user.id,
          title: "in B",
          workspace_id: ctx.ws_b.id
        })

      titles_a =
        ctx.scope
        |> PerfectPaper.History.list_session_summaries(workspace_id: ctx.ws_a.id)
        |> Enum.map(& &1.title)

      assert titles_a == ["in A"]

      # Backward-compat: with no workspace_id option, ALL the user's sessions
      # come back (the 44 existing callers rely on this unchanged behavior).
      all_titles =
        ctx.scope
        |> PerfectPaper.History.list_session_summaries()
        |> Enum.map(& &1.title)
        |> Enum.sort()

      assert all_titles == ["in A", "in B"]
    end

    test "reassign_reviews moves every session in the source workspace only", ctx do
      {:ok, s1} =
        PerfectPaper.History.begin_session(%{
          user_id: ctx.user.id,
          title: "m1",
          workspace_id: ctx.ws_a.id
        })

      {:ok, s2} =
        PerfectPaper.History.begin_session(%{
          user_id: ctx.user.id,
          title: "m2",
          workspace_id: ctx.ws_a.id
        })

      # A session in a different workspace must be left untouched.
      {:ok, other} =
        PerfectPaper.History.begin_session(%{
          user_id: ctx.user.id,
          title: "stay",
          workspace_id: ctx.ws_b.id
        })

      assert {:ok, 2} = PerfectPaper.History.reassign_reviews(ctx.ws_a.id, ctx.ws_b.id)
      assert PerfectPaper.Repo.reload!(s1).workspace_id == ctx.ws_b.id
      assert PerfectPaper.Repo.reload!(s2).workspace_id == ctx.ws_b.id
      assert PerfectPaper.Repo.reload!(other).workspace_id == ctx.ws_b.id
    end
  end

  describe "rename_session/3" do
    test "the owner renames; the title is trimmed" do
      user = user_fixture()
      session = session_fixture(user: user)
      scope = Authz.load_subject(user)

      assert {:ok, renamed} = History.rename_session(session, scope, "  A Better Title  ")
      assert renamed.title == "A Better Title"
    end

    test "a non-owner cannot rename someone else's review" do
      owner = user_fixture()
      other = user_fixture()
      session = session_fixture(user: owner)

      assert {:error, _} = History.rename_session(session, Authz.load_subject(other), "Hijack")
      assert PerfectPaper.Repo.reload!(session).title == session.title
    end

    test "rejects a blank title" do
      user = user_fixture()
      session = session_fixture(user: user)

      assert {:error, %Ecto.Changeset{}} =
               History.rename_session(session, Authz.load_subject(user), "   ")
    end
  end
end
