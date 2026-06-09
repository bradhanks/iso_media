defmodule PerfectPaperWeb.Api.BillingControllerTest do
  use PerfectPaperWeb.ConnCase, async: true
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  alias PerfectPaper.Billing

  setup %{conn: conn} do
    owner = user_fixture()
    org = organization_fixture(owner, %{credit_pool: 0})
    {:ok, owner_key, _} = PerfectPaper.ApiKeys.generate(owner, "ci")

    # Use the statically-configured admin email (config/test.exs) — never mutate
    # the global :admin_emails config (it races other async tests like CreditsTest).
    admin = user_fixture(%{email: "admin@perfectpaper.test"})
    {:ok, admin_key, _} = PerfectPaper.ApiKeys.generate(admin, "ci")

    org_conn =
      conn
      |> put_req_header("authorization", "Bearer " <> owner_key)
      |> put_req_header("accept", "application/json")

    admin_conn =
      conn
      |> put_req_header("authorization", "Bearer " <> admin_key)
      |> put_req_header("accept", "application/json")

    %{org_conn: org_conn, admin_conn: admin_conn, org: org}
  end

  test "org-admin views the contract (none yet → configured:false)", %{org_conn: c, org: org} do
    body = c |> get("/api/orgs/#{org.id}/billing/contract") |> json_response(200)
    assert body["configured"] == false
  end

  test "org-admin is FORBIDDEN from managing (not a platform admin)", %{org_conn: c, org: org} do
    assert c
           |> put("/api/orgs/#{org.id}/billing/contract", %{
             "seats" => 5,
             "term_start" => "2026-06-01",
             "term_end" => "2027-06-01"
           })
           |> json_response(403)
  end

  test "platform-admin creates + activates a contract (amounts server-side)", %{
    admin_conn: c,
    org: org
  } do
    draft =
      c
      |> put("/api/orgs/#{org.id}/billing/contract", %{
        "seats" => 10,
        "price_per_seat_cents" => 5000,
        "per_seat_credits" => 100,
        "interval" => "monthly",
        "term_start" => "2026-06-01",
        "term_end" => "2027-06-01"
      })
      |> json_response(200)

    assert draft["status"] == "draft"
    assert draft["seats"] == 10

    activated = c |> post("/api/orgs/#{org.id}/billing/contract/activate") |> json_response(200)
    assert activated["status"] == "active"
  end

  test "activating a second active contract → 409", %{admin_conn: c, org: org} do
    c
    |> put("/api/orgs/#{org.id}/billing/contract", %{
      "seats" => 5,
      "term_start" => "2026-06-01",
      "term_end" => "2027-06-01"
    })

    c |> post("/api/orgs/#{org.id}/billing/contract/activate")

    c
    |> put("/api/orgs/#{org.id}/billing/contract", %{
      "seats" => 6,
      "term_start" => "2026-06-01",
      "term_end" => "2027-06-01"
    })

    assert c |> post("/api/orgs/#{org.id}/billing/contract/activate") |> json_response(409)
  end

  test "platform-admin marks an invoice paid", %{admin_conn: c, org: org} do
    {:ok, contract} =
      Billing.create_contract(org, %{
        organization_id: org.id,
        seats: 3,
        per_seat_credits: 10,
        price_per_seat_cents: 1000,
        term_start: Date.utc_today(),
        term_end: Date.add(Date.utc_today(), 365)
      })

    {:ok, _} = Billing.activate_contract(contract)
    [inv] = Billing.list_invoices(org.id)

    body =
      c |> post("/api/orgs/#{org.id}/billing/invoices/#{inv.id}/mark-paid") |> json_response(200)

    assert body["status"] == "paid"
  end

  test "unknown org → 404", %{org_conn: c} do
    assert c |> get("/api/orgs/#{Ecto.UUID.generate()}/billing/contract") |> json_response(404)
  end
end
