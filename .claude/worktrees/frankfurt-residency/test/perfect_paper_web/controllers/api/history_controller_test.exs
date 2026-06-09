defmodule PerfectPaperWeb.Api.HistoryControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(user, "ci")

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user}
  end

  test "GET /api/history lists the user's sessions", %{conn: conn, user: user} do
    _s = session_fixture(user: user)
    resp = conn |> get(~p"/api/history") |> json_response(200)
    assert [%{"title" => "Doc"}] = resp["data"]
  end

  test "GET /api/history/:id returns a session with comments", %{conn: conn, user: user} do
    session = session_fixture(user: user)
    _c = comment_fixture(session)
    resp = conn |> get(~p"/api/history/#{session.id}") |> json_response(200)
    assert resp["data"]["id"] == session.id
    assert length(resp["data"]["comments"]) == 1
  end

  test "GET /api/history/:id 404s for a missing session", %{conn: conn} do
    resp = conn |> get(~p"/api/history/#{Ecto.UUID.generate()}") |> json_response(404)
    assert resp == %{"detail" => "Not found"}
  end

  test "PATCH dismiss marks a comment dismissed", %{conn: conn, user: user} do
    session = session_fixture(user: user)
    comment = comment_fixture(session)

    resp =
      conn
      |> patch(~p"/api/history/#{session.id}/comments/#{comment.id}/dismiss")
      |> json_response(200)

    assert resp["data"]["status"] == "dismissed"
  end

  test "POST mark-viewed flips the viewed flag", %{conn: conn, user: user} do
    session = session_fixture(user: user)
    resp = conn |> post(~p"/api/history/#{session.id}/mark-viewed") |> json_response(200)
    assert resp["data"]["viewed"] == true
  end

  test "DELETE removes a session", %{conn: conn, user: user} do
    session = session_fixture(user: user)
    assert conn |> delete(~p"/api/history/#{session.id}") |> response(204)
    assert conn |> get(~p"/api/history/#{session.id}") |> json_response(404)
  end

  test "401 without a token" do
    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> get(~p"/api/history")
           |> json_response(401)
  end

  describe "ownership scoping" do
    setup %{conn: conn} do
      other = user_fixture()
      session = session_fixture(user: other)
      comment = comment_fixture(session)
      {:ok, conn: conn, other_session: session, other_comment: comment}
    end

    test "GET another user's session 404s", %{conn: conn, other_session: s} do
      assert conn |> get(~p"/api/history/#{s.id}") |> json_response(404)
    end

    test "DELETE another user's session 404s and leaves it intact",
         %{conn: conn, other_session: s} do
      assert conn |> delete(~p"/api/history/#{s.id}") |> json_response(404)
      assert PerfectPaper.Repo.get(PerfectPaper.History.Session, s.id)
    end

    test "PATCH visibility on another user's session 404s", %{conn: conn, other_session: s} do
      assert conn
             |> patch(~p"/api/history/#{s.id}/visibility", %{is_public: true})
             |> json_response(404)
    end

    test "POST mark-viewed on another user's session 404s", %{conn: conn, other_session: s} do
      assert conn |> post(~p"/api/history/#{s.id}/mark-viewed") |> json_response(404)
    end

    test "PATCH dismiss on another user's comment 404s",
         %{conn: conn, other_session: s, other_comment: c} do
      assert conn
             |> patch(~p"/api/history/#{s.id}/comments/#{c.id}/dismiss")
             |> json_response(404)
    end
  end

  describe "POST /api/history/:id/comments" do
    import PerfectPaper.AuthzFixtures

    test "commenter-grantee can add a comment (201, author fields present)",
         %{conn: conn, user: user} do
      owner = user_fixture()
      session = session_fixture(user: owner)
      session_grant_fixture(session, user, :commenter)

      resp =
        conn
        |> post(~p"/api/history/#{session.id}/comments", %{body: "Nice work on section 2."})
        |> json_response(201)

      assert resp["data"]["body"] == "Nice work on section 2."
      assert resp["data"]["author_type"] == "user"
      assert is_binary(resp["data"]["author_id"])
    end

    test "viewer-grantee gets 403",
         %{conn: conn, user: user} do
      owner = user_fixture()
      session = session_fixture(user: owner)
      session_grant_fixture(session, user, :viewer)

      assert conn
             |> post(~p"/api/history/#{session.id}/comments", %{body: "Hello"})
             |> json_response(403)
    end

    test "commenter can reply with parent_id (201, parent_id set)",
         %{conn: conn, user: user} do
      owner = user_fixture()
      session = session_fixture(user: owner)
      parent_comment = comment_fixture(session)
      session_grant_fixture(session, user, :commenter)

      resp =
        conn
        |> post(~p"/api/history/#{session.id}/comments", %{
          body: "Agreed!",
          parent_id: parent_comment.id
        })
        |> json_response(201)

      assert resp["data"]["parent_id"] == parent_comment.id
    end

    test "missing session returns 404", %{conn: conn} do
      assert conn
             |> post(~p"/api/history/#{Ecto.UUID.generate()}/comments", %{body: "Hi"})
             |> json_response(404)
    end
  end

  describe "POST /api/history/:id/invitations" do
    test "session owner can invite a new guest by email (201, user created)",
         %{conn: conn, user: user} do
      session = session_fixture(user: user)

      resp =
        conn
        |> post(~p"/api/history/#{session.id}/invitations", %{
          email: "guest_#{System.unique_integer([:positive])}@example.com",
          role: "commenter"
        })
        |> json_response(201)

      assert resp["data"]["role"] == "commenter"
      assert is_binary(resp["data"]["user_id"])
    end

    test "non-owner without :share gets 403",
         %{conn: conn, user: user} do
      import PerfectPaper.AuthzFixtures, only: [session_grant_fixture: 3]
      owner = user_fixture()
      session = session_fixture(user: owner)
      session_grant_fixture(session, user, :commenter)

      assert conn
             |> post(~p"/api/history/#{session.id}/invitations", %{
               email: "another@example.com",
               role: "commenter"
             })
             |> json_response(403)
    end

    test "non-existent session returns 404", %{conn: conn} do
      assert conn
             |> post(~p"/api/history/#{Ecto.UUID.generate()}/invitations", %{
               email: "x@example.com",
               role: "commenter"
             })
             |> json_response(404)
    end
  end

  describe "authorization status codes" do
    import PerfectPaper.HistoryFixtures

    test "GET show on another user's session is 404 (existence hidden)", %{conn: conn} do
      other = session_fixture()
      conn = get(conn, ~p"/api/history/#{other.id}")
      assert json_response(conn, 404)
    end

    test "dismiss on a visible-but-under-roled session is 403", %{conn: conn, user: user} do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      comment = comment_fixture(session)
      PerfectPaper.AuthzFixtures.session_grant_fixture(session, user, :commenter)

      conn = patch(conn, ~p"/api/history/#{session.id}/comments/#{comment.id}/dismiss")
      assert json_response(conn, 403)
    end

    test "delete on a visible-but-under-roled session is 403", %{conn: conn, user: user} do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      PerfectPaper.AuthzFixtures.session_grant_fixture(session, user, :viewer)
      conn = delete(conn, ~p"/api/history/#{session.id}")
      assert json_response(conn, 403)
    end

    test "set_visibility on a visible-but-under-roled session is 403", %{conn: conn, user: user} do
      owner = PerfectPaper.AccountsFixtures.user_fixture()
      session = session_fixture(user: owner)
      PerfectPaper.AuthzFixtures.session_grant_fixture(session, user, :viewer)
      conn = patch(conn, ~p"/api/history/#{session.id}/visibility", %{is_public: true})
      assert json_response(conn, 403)
    end

    test "owner can delete their own session", %{conn: conn, user: user} do
      session = session_fixture(user: user)
      assert conn |> delete(~p"/api/history/#{session.id}") |> response(204)
    end

    test "owner can set_visibility on their own session", %{conn: conn, user: user} do
      session = session_fixture(user: user)

      resp =
        conn
        |> patch(~p"/api/history/#{session.id}/visibility", %{is_public: true})
        |> json_response(200)

      assert resp["data"]["is_public"] == true
    end
  end
end
