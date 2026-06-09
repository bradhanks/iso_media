defmodule PerfectPaperWeb.Api.WebhookControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  import PerfectPaper.WebhooksFixtures

  # ---------------------------------------------------------------------------
  # Setup: authed user who owns an org
  # ---------------------------------------------------------------------------

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(user, "ci")
    org = organization_fixture(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user, org: org}
  end

  # ---------------------------------------------------------------------------
  # index
  # ---------------------------------------------------------------------------

  test "GET /api/webhooks returns empty list when no endpoints exist",
       %{conn: conn} do
    resp = conn |> get(~p"/api/webhooks") |> json_response(200)
    assert resp["data"] == []
  end

  test "GET /api/webhooks lists existing endpoints (no secret)", %{conn: conn, org: org} do
    endpoint_fixture(org, %{url: "https://listed.example.com/hook"})
    resp = conn |> get(~p"/api/webhooks") |> json_response(200)
    assert [item] = resp["data"]
    assert item["url"] == "https://listed.example.com/hook"
    refute Map.has_key?(item, "secret")
  end

  # ---------------------------------------------------------------------------
  # create
  # ---------------------------------------------------------------------------

  test "POST /api/webhooks creates an endpoint and returns 201 with secret",
       %{conn: conn} do
    params = %{url: "https://create.example.com/hook", event_types: ["session.completed"]}
    resp = conn |> post(~p"/api/webhooks", params) |> json_response(201)
    data = resp["data"]
    assert data["url"] == "https://create.example.com/hook"
    assert data["event_types"] == ["session.completed"]
    assert is_binary(data["secret"]) and data["secret"] != ""
  end

  test "POST /api/webhooks returns 422 for an invalid URL", %{conn: conn} do
    params = %{url: "not-a-url", event_types: ["session.completed"]}
    resp = conn |> post(~p"/api/webhooks", params) |> json_response(422)
    assert resp["detail"] != nil
  end

  # ---------------------------------------------------------------------------
  # show
  # ---------------------------------------------------------------------------

  test "GET /api/webhooks/:id returns the endpoint without secret",
       %{conn: conn, org: org} do
    ep = endpoint_fixture(org)
    resp = conn |> get(~p"/api/webhooks/#{ep.id}") |> json_response(200)
    assert resp["data"]["id"] == ep.id
    refute Map.has_key?(resp["data"], "secret")
  end

  test "GET /api/webhooks/:id returns 404 for unknown id", %{conn: conn} do
    resp = conn |> get(~p"/api/webhooks/#{Ecto.UUID.generate()}") |> json_response(404)
    assert resp["detail"] == "Not found"
  end

  # ---------------------------------------------------------------------------
  # update
  # ---------------------------------------------------------------------------

  test "PATCH /api/webhooks/:id updates url and event_types", %{conn: conn, org: org} do
    ep = endpoint_fixture(org)

    resp =
      conn
      |> patch(~p"/api/webhooks/#{ep.id}", %{
        url: "https://updated.example.com/hook",
        event_types: ["session.completed"]
      })
      |> json_response(200)

    assert resp["data"]["url"] == "https://updated.example.com/hook"
    refute Map.has_key?(resp["data"], "secret")
  end

  test "PATCH /api/webhooks/:id returns 404 for unknown id", %{conn: conn} do
    resp =
      conn
      |> patch(~p"/api/webhooks/#{Ecto.UUID.generate()}", %{url: "https://x.example.com/"})
      |> json_response(404)

    assert resp["detail"] == "Not found"
  end

  # ---------------------------------------------------------------------------
  # delete
  # ---------------------------------------------------------------------------

  test "DELETE /api/webhooks/:id removes the endpoint", %{conn: conn, org: org} do
    ep = endpoint_fixture(org)
    assert conn |> delete(~p"/api/webhooks/#{ep.id}") |> response(204)
    assert conn |> get(~p"/api/webhooks/#{ep.id}") |> json_response(404)
  end

  test "DELETE /api/webhooks/:id returns 404 for unknown id", %{conn: conn} do
    resp = conn |> delete(~p"/api/webhooks/#{Ecto.UUID.generate()}") |> json_response(404)
    assert resp["detail"] == "Not found"
  end

  # ---------------------------------------------------------------------------
  # rotate_secret
  # ---------------------------------------------------------------------------

  test "POST /api/webhooks/:id/rotate-secret returns new secret", %{conn: conn, org: org} do
    ep = endpoint_fixture(org, %{secret: "original_secret"})

    resp =
      conn
      |> post(~p"/api/webhooks/#{ep.id}/rotate-secret")
      |> json_response(200)

    data = resp["data"]
    assert is_binary(data["secret"]) and data["secret"] != ""
    assert data["secret"] != "original_secret"
  end

  # ---------------------------------------------------------------------------
  # deliveries
  # ---------------------------------------------------------------------------

  test "GET /api/webhooks/:id/deliveries returns empty list when no deliveries",
       %{conn: conn, org: org} do
    ep = endpoint_fixture(org)
    resp = conn |> get(~p"/api/webhooks/#{ep.id}/deliveries") |> json_response(200)
    assert resp["data"] == []
  end

  # ---------------------------------------------------------------------------
  # No-admin-org → 403
  # ---------------------------------------------------------------------------

  describe "user with no admin org" do
    setup %{conn: conn} do
      non_admin = user_fixture()
      {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(non_admin, "ci")

      no_admin_conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("accept", "application/json")

      {:ok, no_admin_conn: no_admin_conn}
    end

    test "GET /api/webhooks → 403", %{no_admin_conn: conn} do
      resp = conn |> get(~p"/api/webhooks") |> json_response(403)
      assert resp["detail"] == "Forbidden"
    end

    test "POST /api/webhooks → 403", %{no_admin_conn: conn} do
      resp =
        conn
        |> post(~p"/api/webhooks", %{url: "https://x.example.com/", event_types: []})
        |> json_response(403)

      assert resp["detail"] == "Forbidden"
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-org isolation: endpoint from another org → 404
  # ---------------------------------------------------------------------------

  test "GET /api/webhooks/:id for another org's endpoint returns 403",
       %{conn: conn} do
    other_user = user_fixture()
    other_org = organization_fixture(other_user)
    other_ep = endpoint_fixture(other_org)

    # Webhooks.get_endpoint/2 returns {:error, :unauthorized} when the caller
    # is not an admin of the endpoint's org (existence is not hidden).
    resp = conn |> get(~p"/api/webhooks/#{other_ep.id}") |> json_response(403)
    assert resp["detail"] == "Forbidden"
  end
end
