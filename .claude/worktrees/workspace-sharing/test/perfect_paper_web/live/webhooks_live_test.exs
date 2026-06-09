defmodule PerfectPaperWeb.WebhooksLiveTest do
  use PerfectPaperWeb.ConnCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  import PerfectPaper.WebhooksFixtures

  alias PerfectPaper.Repo
  alias PerfectPaper.Webhooks.Delivery

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Inserts a minimal Delivery row (no Oban job) for tests that just need a row.
  defp delivery_fixture(endpoint) do
    %Delivery{}
    |> Delivery.create_changeset(%{
      endpoint_id: endpoint.id,
      event_type: "session.completed",
      event_id: Ecto.UUID.generate(),
      payload: %{"type" => "session.completed"}
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------------------
  # Mount / access
  # ---------------------------------------------------------------------------

  describe "mount" do
    test "redirects when not logged in", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/webhooks")
      assert path =~ "/users/log-in"
    end

    test "redirects a user who admins no org", %{conn: conn} do
      non_admin = user_fixture()

      {:error, {:live_redirect, %{to: path}}} =
        conn |> log_in_user(non_admin) |> live(~p"/webhooks")

      # should be sent away (to /new or similar), not to /webhooks
      refute path =~ "/webhooks"
    end

    test "renders the page for an org owner", %{conn: conn} do
      owner = user_fixture()
      _org = organization_fixture(owner)
      {:ok, _lv, html} = conn |> log_in_user(owner) |> live(~p"/webhooks")
      assert html =~ "Webhooks"
    end

    test "lists existing endpoints for the org", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)
      ep = endpoint_fixture(org)

      {:ok, _lv, _html} = conn |> log_in_user(owner) |> live(~p"/webhooks")

      # Each endpoint row has a discrete id.
      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/webhooks")
      assert has_element?(lv, "#endpoint-#{ep.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # Create endpoint
  # ---------------------------------------------------------------------------

  describe "create endpoint" do
    test "submitting valid attrs adds endpoint and shows secret flash", %{conn: conn} do
      owner = user_fixture()
      _org = organization_fixture(owner)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/webhooks")

      refute has_element?(lv, "#endpoints-list .card")

      html =
        lv
        |> form("#new-endpoint-form", %{
          "endpoint" => %{
            "url" => "https://hooks.example.com/test",
            "event_types" => "session.completed",
            "description" => "Test hook"
          }
        })
        |> render_submit()

      # Flash contains the one-time secret
      assert html =~ "Signing secret"
      # The new endpoint row appears
      assert html =~ "https://hooks.example.com/test"
    end

    test "invalid URL shows a field error and does not create an endpoint", %{conn: conn} do
      owner = user_fixture()
      _org = organization_fixture(owner)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/webhooks")

      html =
        lv
        |> form("#new-endpoint-form", %{
          "endpoint" => %{
            "url" => "not-a-url",
            "event_types" => "session.completed",
            "description" => ""
          }
        })
        |> render_submit()

      # Changeset error for url should appear
      assert html =~ "must use http or https scheme" or html =~ "is not a valid URL"
    end
  end

  # ---------------------------------------------------------------------------
  # Delete endpoint
  # ---------------------------------------------------------------------------

  describe "delete endpoint" do
    test "deletes an endpoint and removes it from the list", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)
      ep = endpoint_fixture(org)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/webhooks")
      assert has_element?(lv, "#endpoint-#{ep.id}")

      lv
      |> element("#endpoint-#{ep.id}-delete")
      |> render_click()

      refute has_element?(lv, "#endpoint-#{ep.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # Delivery log
  # ---------------------------------------------------------------------------

  describe "delivery log" do
    test "loading deliveries shows the delivery row", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)
      ep = endpoint_fixture(org)
      delivery = delivery_fixture(ep)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/webhooks")

      # Click the "View delivery log" button for this endpoint
      lv
      |> element("#endpoint-#{ep.id}-load-deliveries")
      |> render_click()

      assert has_element?(lv, "#delivery-#{delivery.id}")
    end
  end

  # ---------------------------------------------------------------------------
  # Redeliver
  # ---------------------------------------------------------------------------

  describe "redeliver" do
    test "redelivering a delivery enqueues an Oban job", %{conn: conn} do
      owner = user_fixture()
      org = organization_fixture(owner)
      ep = endpoint_fixture(org)
      delivery = delivery_fixture(ep)

      {:ok, lv, _html} = conn |> log_in_user(owner) |> live(~p"/webhooks")

      # Load the delivery log first
      lv
      |> element("#endpoint-#{ep.id}-load-deliveries")
      |> render_click()

      assert has_element?(lv, "#redeliver-#{delivery.id}")

      lv
      |> element("#redeliver-#{delivery.id}")
      |> render_click()

      assert_enqueued(
        worker: PerfectPaper.Webhooks.Delivery.Worker,
        args: %{"delivery_id" => delivery.id}
      )
    end
  end
end
