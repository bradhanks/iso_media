defmodule PerfectPaperWeb.ApiDocsTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "GET /api/openapi.json serves a valid OpenAPI document", %{conn: conn} do
    conn = get(conn, "/api/openapi.json")
    body = json_response(conn, 200)
    assert body["openapi"] =~ ~r/^3\./
    assert body["info"]["title"] == "PerfectPaper API"
    assert is_map(body["paths"])
  end

  test "schema modules resolve with titles" do
    assert PerfectPaperWeb.Api.Schemas.Session.schema().title == "Session"
    assert PerfectPaperWeb.Api.Schemas.Comment.schema().title == "Comment"
    assert PerfectPaperWeb.Api.Schemas.Error.schema().title == "Error"
    assert PerfectPaperWeb.Api.Schemas.CreditScore.schema().title == "CreditScore"
    assert PerfectPaperWeb.Api.Schemas.LoginRequest.schema().title == "LoginRequest"
    assert PerfectPaperWeb.Api.Schemas.WebhookEndpoint.schema().title == "WebhookEndpoint"
    assert PerfectPaperWeb.Api.Schemas.WebhookDelivery.schema().title == "WebhookDelivery"
    assert PerfectPaperWeb.Api.Schemas.AddCommentRequest.schema().title == "AddCommentRequest"
    assert PerfectPaperWeb.Api.Schemas.InvitationRequest.schema().title == "InvitationRequest"
    assert PerfectPaperWeb.Api.Schemas.Invitation.schema().title == "Invitation"
    assert PerfectPaperWeb.Api.Schemas.SsoConfig.schema().title == "SsoConfig"
    assert PerfectPaperWeb.Api.Schemas.SsoConfigRequest.schema().title == "SsoConfigRequest"
    assert PerfectPaperWeb.Api.Schemas.SsoEnableRequest.schema().title == "SsoEnableRequest"
  end

  test "documents the history + credit endpoints", %{conn: conn} do
    paths = get(conn, "/api/openapi.json") |> json_response(200) |> Map.fetch!("paths")
    assert Map.has_key?(paths, "/api/history")
    assert Map.has_key?(paths, "/api/history/{id}")
    assert Map.has_key?(paths, "/api/credit-score")
    assert get_in(paths, ["/api/history/{id}", "get"]) != nil
  end

  test "documents the webhook endpoints", %{conn: conn} do
    paths = get(conn, "/api/openapi.json") |> json_response(200) |> Map.fetch!("paths")
    assert Map.has_key?(paths, "/api/webhooks")
    assert Map.has_key?(paths, "/api/webhooks/{id}")
    assert get_in(paths, ["/api/webhooks", "get"]) != nil
    assert get_in(paths, ["/api/webhooks", "post"]) != nil
    assert get_in(paths, ["/api/webhooks/{id}", "get"]) != nil
    assert get_in(paths, ["/api/webhooks/{id}", "patch"]) != nil
    assert get_in(paths, ["/api/webhooks/{id}", "delete"]) != nil
  end

  test "documents the SSO management endpoints", %{conn: conn} do
    paths = get(conn, "/api/openapi.json") |> json_response(200) |> Map.fetch!("paths")
    assert get_in(paths, ["/api/orgs/{org_id}/sso", "get"]) != nil
    assert get_in(paths, ["/api/orgs/{org_id}/sso", "put"]) != nil
    assert get_in(paths, ["/api/orgs/{org_id}/sso/verify-domain", "post"]) != nil
    assert get_in(paths, ["/api/orgs/{org_id}/sso/enable", "post"]) != nil

    # The redacted SsoConfig response schema must NOT carry the secret fields.
    props = PerfectPaperWeb.Api.Schemas.SsoConfig.schema().properties
    refute Map.has_key?(props, :oidc_client_secret)
    refute Map.has_key?(props, :saml_idp_cert)
    assert Map.has_key?(props, :oidc_client_secret_set)
    assert Map.has_key?(props, :saml_idp_cert_set)
  end

  test "documents the auth endpoints", %{conn: conn} do
    paths = get(conn, "/api/openapi.json") |> json_response(200) |> Map.fetch!("paths")
    assert Map.has_key?(paths, "/users/log-in")
    assert Map.has_key?(paths, "/auth/{provider}")
  end

  test "GET /api/docs serves a Redoc reference page for the spec", %{conn: conn} do
    html = get(conn, "/api/docs") |> html_response(200)
    assert html =~ "redoc"
    assert html =~ "/api/openapi.json"
  end

  test "the OpenAPI spec builds and serializes without error" do
    spec = PerfectPaperWeb.Api.Spec.spec()
    assert %OpenApiSpex.OpenApi{} = spec
    # to_map/1 raises on a structurally-invalid spec
    map = OpenApiSpex.OpenApi.to_map(spec)
    assert is_map(map["paths"])
    assert map["openapi"] =~ ~r/^3\./
  end

  test "all documented REST endpoints appear in the spec", %{conn: conn} do
    paths = get(conn, "/api/openapi.json") |> json_response(200) |> Map.fetch!("paths")

    expected = [
      "/api/history",
      "/api/history/{id}",
      "/api/history/{id}/mark-viewed",
      "/api/history/{id}/visibility",
      "/api/history/{session_id}/comments/{comment_id}/dismiss",
      "/api/history/{session_id}/comments/{comment_id}/address",
      "/api/history/{id}/comments",
      "/api/history/{id}/invitations",
      "/api/credit-score",
      "/api/webhooks",
      "/api/webhooks/{id}",
      "/api/webhooks/{id}/rotate-secret",
      "/api/webhooks/{id}/deliveries",
      "/api/orgs/{org_id}/sso",
      "/api/orgs/{org_id}/sso/verify-domain",
      "/api/orgs/{org_id}/sso/enable",
      "/users/log-in",
      "/users/log-out",
      "/users/update-password",
      "/auth/{provider}",
      "/auth/{provider}/callback"
    ]

    for path <- expected do
      assert Map.has_key?(paths, path), "missing OpenAPI path: #{path}"
    end
  end
end
