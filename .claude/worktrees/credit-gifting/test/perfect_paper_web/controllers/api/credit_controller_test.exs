defmodule PerfectPaperWeb.Api.CreditControllerTest do
  use PerfectPaperWeb.ConnCase, async: true

  alias PerfectPaper.Credits

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.CreditsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, raw, _key} = PerfectPaper.ApiKeys.generate(user, "ci")

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user}
  end

  test "GET /api/credit-score returns the camelCase balance envelope", %{conn: conn, user: user} do
    grant_fixture(user, 100)
    {:ok, _, _} = Credits.charge_for_proofreading(user.id)

    resp = conn |> get(~p"/api/credit-score") |> json_response(200)

    # Boundary quirk preserved from Refine: camelCase only at the REST edge.
    # 1 credit = 1 full review, so charging once leaves 99.
    assert resp["paidCreditsRemaining"] == 99
    assert resp["previewCreditsRemaining"] == 0
  end

  test "GET /api/credit-score reports paid and preview buckets separately", %{
    conn: conn,
    user: user
  } do
    Credits.grant(user.id, 4, "subscription", :paid)
    Credits.grant(user.id, 2, "promo", :preview)

    resp = conn |> get(~p"/api/credit-score") |> json_response(200)

    assert resp["paidCreditsRemaining"] == 4
    assert resp["previewCreditsRemaining"] == 2
  end

  test "GET /api/credit-score is zero for a new user", %{conn: conn} do
    resp = conn |> get(~p"/api/credit-score") |> json_response(200)
    assert resp["paidCreditsRemaining"] == 0
    assert resp["previewCreditsRemaining"] == 0
  end

  test "401 without a token" do
    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> get(~p"/api/credit-score")
           |> json_response(401)
  end
end
