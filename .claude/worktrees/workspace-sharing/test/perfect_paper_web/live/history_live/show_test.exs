defmodule PerfectPaperWeb.HistoryLive.ShowTest do
  @moduledoc """
  LiveView tests for the session show page: threaded comments, composer, and
  collaborators panel.
  """
  use PerfectPaperWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  alias PerfectPaper.{Authz, History, Repo}
  alias PerfectPaper.AuthzFixtures
  alias PerfectPaper.History.Comment

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp human_comment_fixture(session, user, attrs) do
    attrs = Map.new(attrs)
    body = Map.get(attrs, :body, "A human comment body")
    parent_id = Map.get(attrs, :parent_id)

    {:ok, comment} =
      %Comment{}
      |> Comment.author_changeset(%{
        session_id: session.id,
        author_id: user.id,
        body: body,
        parent_id: parent_id
      })
      |> Repo.insert()

    comment
  end

  # ---------------------------------------------------------------------------
  # Owner sees both panels
  # ---------------------------------------------------------------------------

  describe "Show as owner" do
    test "owner sees comment composer and collaborators panel", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)

      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/history/#{session.id}")

      assert html =~ ~s(id="comment-composer")
      assert html =~ ~s(id="collaborators-panel")
    end

    test "owner can add a top-level comment and it appears on the page", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/history/#{session.id}")

      html =
        lv
        |> form("#comment-composer form",
          comment: %{body: "Great observation here.", parent_id: ""}
        )
        |> render_submit()

      # Reload to get the id from the newly inserted comment
      sc = Authz.load_subject(user)
      updated_session = History.get_session(session.id, sc)
      [comment] = Enum.filter(updated_session.comments, &(&1.author_type == :user))

      assert html =~ ~s(id="comment-#{comment.id}")
    end

    test "owner can post a reply and it nests under the parent", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)
      parent = human_comment_fixture(session, user, body: "Parent comment")

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/history/#{session.id}")

      # Open the reply form
      lv |> element("#reply-#{parent.id}") |> render_click()

      html =
        lv
        |> form("#reply-form-#{parent.id} form",
          comment: %{body: "A reply to parent", parent_id: parent.id}
        )
        |> render_submit()

      sc = Authz.load_subject(user)
      updated_session = History.get_session(session.id, sc)

      reply =
        Enum.find(updated_session.comments, fn c ->
          c.author_type == :user and c.parent_id == parent.id
        end)

      assert reply != nil
      assert html =~ ~s(id="replies-#{parent.id}")
      assert html =~ ~s(id="comment-#{reply.id}")
    end

    test "owner sees invite form in collaborators panel", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)

      {:ok, _lv, html} = conn |> log_in_user(user) |> live(~p"/history/#{session.id}")

      assert html =~ ~s(id="invite-form")
    end

    test "owner invites by email and grant appears", %{conn: conn} do
      owner = user_fixture()
      invitee = user_fixture()
      session = session_fixture(user: owner)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/history/#{session.id}")

      html =
        lv
        |> form("#invite-form form", invite: %{email: invitee.email, role: "commenter"})
        |> render_submit()

      assert html =~ ~s(id="grant-#{invitee.id}")
    end

    test "owner revokes a grant and it disappears", %{conn: conn} do
      owner = user_fixture()
      grantee = user_fixture()
      session = session_fixture(user: owner)
      AuthzFixtures.session_grant_fixture(session, grantee, :commenter)

      {:ok, lv, html} = conn |> log_in_user(owner) |> live(~p"/history/#{session.id}")

      assert html =~ ~s(id="grant-#{grantee.id}")

      html =
        lv
        |> element("#revoke-#{grantee.id}")
        |> render_click()

      refute html =~ ~s(id="grant-#{grantee.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # Commenter grantee: sees composer, NOT the collaborators panel
  # ---------------------------------------------------------------------------

  describe "Show as commenter grantee" do
    test "commenter sees comment composer but not collaborators panel", %{conn: conn} do
      owner = user_fixture()
      commenter = user_fixture()
      session = session_fixture(user: owner)
      AuthzFixtures.session_grant_fixture(session, commenter, :commenter)

      {:ok, _lv, html} = conn |> log_in_user(commenter) |> live(~p"/history/#{session.id}")

      assert html =~ ~s(id="comment-composer")
      refute html =~ ~s(id="collaborators-panel")
    end

    test "commenter can post a comment", %{conn: conn} do
      owner = user_fixture()
      commenter = user_fixture()
      session = session_fixture(user: owner)
      AuthzFixtures.session_grant_fixture(session, commenter, :commenter)

      {:ok, lv, _html} = conn |> log_in_user(commenter) |> live(~p"/history/#{session.id}")

      html =
        lv
        |> form("#comment-composer form", comment: %{body: "From the commenter.", parent_id: ""})
        |> render_submit()

      sc = Authz.load_subject(commenter)
      updated_session = History.get_session(session.id, sc)

      [user_comment] = Enum.filter(updated_session.comments, &(&1.author_type == :user))
      assert html =~ ~s(id="comment-#{user_comment.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # Viewer grantee: sees neither composer nor collaborators panel
  # ---------------------------------------------------------------------------

  describe "Show as viewer grantee" do
    test "viewer sees neither comment composer nor collaborators panel", %{conn: conn} do
      owner = user_fixture()
      viewer = user_fixture()
      session = session_fixture(user: owner)
      AuthzFixtures.session_grant_fixture(session, viewer, :viewer)

      {:ok, _lv, html} = conn |> log_in_user(viewer) |> live(~p"/history/#{session.id}")

      refute html =~ ~s(id="comment-composer")
      refute html =~ ~s(id="collaborators-panel")
    end
  end

  # ---------------------------------------------------------------------------
  # Unauthenticated / unauthorized
  # ---------------------------------------------------------------------------

  describe "Show unauthorized" do
    test "redirects when not logged in", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/history/#{session.id}")
      assert path =~ "/users/log-in"
    end

    test "redirects when user has no access to the session", %{conn: conn} do
      owner = user_fixture()
      intruder = user_fixture()
      session = session_fixture(user: owner)

      # The session is invisible to the intruder — get_session returns nil,
      # so the LiveView redirects with a "Session not found" flash.
      assert {:error, {:live_redirect, %{to: "/history"}}} =
               conn |> log_in_user(intruder) |> live(~p"/history/#{session.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # Fix 2: AI badge is rendered for AI-authored comments
  # ---------------------------------------------------------------------------

  describe "AI badge" do
    test "AI comment renders the AI reviewer badge", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)
      # comment_fixture defaults to author_type: :ai
      ai_comment = comment_fixture(session, suggestion: "improve", original_text: "bad prose")

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/history/#{session.id}")

      assert has_element?(lv, "#ai-badge-#{ai_comment.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # Fix 3: author byline shows email local-part, not full address
  # ---------------------------------------------------------------------------

  describe "Author byline" do
    test "human comment byline shows local-part only, not full email", %{conn: conn} do
      owner = user_fixture()
      alice = user_fixture(email: "alice@example.com")
      session = session_fixture(user: owner)
      AuthzFixtures.session_grant_fixture(session, alice, :commenter)
      human_comment_fixture(session, alice, body: "My annotation here.")

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/history/#{session.id}")
      html = render(lv)

      assert html =~ "alice"
      refute html =~ "alice@example.com"
    end
  end

  # ---------------------------------------------------------------------------
  # Fix 1: forged role in invite event defaults gracefully (no crash)
  # ---------------------------------------------------------------------------

  describe "Safe role whitelist" do
    test "invite with unknown role defaults to commenter and does not crash", %{conn: conn} do
      owner = user_fixture()
      invitee = user_fixture()
      session = session_fixture(user: owner)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/history/#{session.id}")

      html =
        lv
        |> render_hook("invite", %{
          "invite" => %{"email" => invitee.email, "role" => "superadmin"}
        })

      # Page should still render (no crash) and the invite goes through as commenter
      assert html =~ ~s(id="grant-#{invitee.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # Existing tests: dismiss / address / undo still work
  # ---------------------------------------------------------------------------

  describe "Show (dismiss/address/undo regression)" do
    test "renders feedback and dismisses a comment", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)
      comment = comment_fixture(session, suggestion: "the", original_text: "teh")

      {:ok, lv, html} = conn |> log_in_user(user) |> live(~p"/history/#{session.id}")
      assert html =~ "the"

      html =
        lv
        |> element("button[phx-click='dismiss'][phx-value-id='#{comment.id}']")
        |> render_click()

      assert html =~ "Undo"
    end

    test "marks the session viewed when the owner opens it", %{conn: conn} do
      user = user_fixture()
      session = session_fixture(user: user)
      refute Repo.reload!(session).viewed

      {:ok, _lv, _html} = conn |> log_in_user(user) |> live(~p"/history/#{session.id}")

      assert Repo.reload!(session).viewed
    end
  end
end
