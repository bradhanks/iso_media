defmodule PerfectPaper.WebhooksTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  alias PerfectPaper.Events
  alias PerfectPaper.Events.Event
  alias PerfectPaper.Repo
  alias PerfectPaper.Webhooks
  alias PerfectPaper.Webhooks.{Delivery, Delivery.Worker, Endpoint}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp endpoint_fixture(org_id, attrs \\ %{}) do
    defaults = %{
      organization_id: org_id,
      url: "https://example.com/webhook",
      secret: "test_secret_#{System.unique_integer()}",
      event_types: ["session.completed"],
      active: true
    }

    %Endpoint{}
    |> Endpoint.create_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp event_fixture(org_id, type \\ :"session.completed") do
    %Event{
      id: Ecto.UUID.generate(),
      type: type,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second),
      organization_id: org_id,
      resource: %{"type" => "session", "id" => Ecto.UUID.generate()},
      data: %{"status" => "complete"}
    }
  end

  # ---------------------------------------------------------------------------
  # dispatch/1
  # ---------------------------------------------------------------------------

  describe "dispatch/1" do
    test "inserts a pending Delivery and enqueues a Worker job for a matching endpoint" do
      user = user_fixture()
      org = organization_fixture(user)
      endpoint = endpoint_fixture(org.id)
      event = event_fixture(org.id)

      assert :ok = Webhooks.dispatch(event)

      # One delivery row created
      delivery = Repo.one!(from d in Delivery, where: d.endpoint_id == ^endpoint.id)
      assert delivery.event_type == "session.completed"
      assert delivery.event_id == event.id
      assert delivery.status == :pending
      assert delivery.payload["type"] == "session.completed"
      assert delivery.payload["organization_id"] == org.id

      # Oban job enqueued
      assert_enqueued(worker: Worker, args: %{"delivery_id" => delivery.id})
    end

    test "is idempotent: dispatching the same event twice creates one delivery and one job" do
      user = user_fixture()
      org = organization_fixture(user)
      endpoint = endpoint_fixture(org.id)
      event = event_fixture(org.id)

      assert :ok = Webhooks.dispatch(event)
      assert :ok = Webhooks.dispatch(event)

      assert Repo.aggregate(
               from(d in Delivery, where: d.endpoint_id == ^endpoint.id),
               :count,
               :id
             ) ==
               1

      assert length(all_enqueued(worker: Worker)) == 1
    end

    test "no delivery or job when org has no active matching endpoint" do
      user = user_fixture()
      org = organization_fixture(user)
      event = event_fixture(org.id)

      # No endpoint registered
      assert :ok = Webhooks.dispatch(event)

      refute_enqueued(worker: Worker)
      assert Repo.aggregate(Delivery, :count, :id) == 0
    end

    test "no delivery or job when endpoint is inactive" do
      user = user_fixture()
      org = organization_fixture(user)
      _endpoint = endpoint_fixture(org.id, %{active: false})
      event = event_fixture(org.id)

      assert :ok = Webhooks.dispatch(event)

      refute_enqueued(worker: Worker)
      assert Repo.aggregate(Delivery, :count, :id) == 0
    end

    test "no delivery or job when endpoint does not subscribe to the event type" do
      user = user_fixture()
      org = organization_fixture(user)
      _endpoint = endpoint_fixture(org.id, %{event_types: ["comment.addressed"]})
      event = event_fixture(org.id, :"session.completed")

      assert :ok = Webhooks.dispatch(event)

      refute_enqueued(worker: Worker)
      assert Repo.aggregate(Delivery, :count, :id) == 0
    end

    test "silently returns :ok when event has no organization_id" do
      event = %Event{
        id: Ecto.UUID.generate(),
        type: :"session.completed",
        organization_id: nil,
        resource: %{},
        data: %{}
      }

      assert :ok = Webhooks.dispatch(event)
      refute_enqueued(worker: Worker)
    end

    test "fans out to multiple endpoints in the same org" do
      user = user_fixture()
      org = organization_fixture(user)
      ep1 = endpoint_fixture(org.id, %{url: "https://a.example.com/hook"})
      ep2 = endpoint_fixture(org.id, %{url: "https://b.example.com/hook"})
      event = event_fixture(org.id)

      assert :ok = Webhooks.dispatch(event)

      assert_enqueued(worker: Worker)

      count =
        Repo.aggregate(
          from(d in Delivery, where: d.endpoint_id in ^[ep1.id, ep2.id]),
          :count,
          :id
        )

      assert count == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Delivery.Worker — success path
  # ---------------------------------------------------------------------------

  describe "Delivery.Worker success" do
    setup do
      user = user_fixture()
      org = organization_fixture(user)
      endpoint = endpoint_fixture(org.id, %{secret: "super_secret"})
      event = event_fixture(org.id)
      Webhooks.dispatch(event)
      delivery = Repo.one!(from d in Delivery, where: d.endpoint_id == ^endpoint.id)
      %{delivery: delivery, endpoint: endpoint}
    end

    test "returns :ok, marks delivery :delivered", %{delivery: delivery} do
      Process.put(:webhook_stub_result, {:ok, 200})
      assert :ok = perform_job(Worker, %{"delivery_id" => delivery.id})

      updated = Repo.reload!(delivery)
      assert updated.status == :delivered
      assert updated.attempts == 1
      assert updated.response_status == 200
      assert updated.delivered_at != nil
      assert updated.last_error == nil
    end

    test "sends correct headers including Stripe-style HMAC signature", %{
      delivery: delivery,
      endpoint: endpoint
    } do
      Process.put(:webhook_stub_result, {:ok, 200})
      perform_job(Worker, %{"delivery_id" => delivery.id})

      assert_received {:webhook_delivered, %{body: body, headers: headers}}

      # Find the signature header
      sig_header =
        Enum.find_value(headers, fn
          {"x-perfectpaper-signature", v} -> v
          _ -> nil
        end)

      refute is_nil(sig_header), "missing x-perfectpaper-signature header"

      # Parse t= and v1= from "t=<ts>,v1=<hex>"
      %{"t" => ts_str, "v1" => v1} =
        Regex.named_captures(~r/t=(?<t>\d+),v1=(?<v1>[0-9a-f]+)/, sig_header)

      ts = String.to_integer(ts_str)

      # Recompute and compare
      expected =
        :crypto.mac(:hmac, :sha256, endpoint.secret, "#{ts}.#{body}")
        |> Base.encode16(case: :lower)

      assert v1 == expected

      # Verify other required headers
      assert {"content-type", "application/json"} in headers
      assert {"x-perfectpaper-event", "session.completed"} in headers
      assert {"x-perfectpaper-delivery", delivery.id} in headers
    end

    test "sends correct URL", %{delivery: delivery} do
      Process.put(:webhook_stub_result, {:ok, 200})
      perform_job(Worker, %{"delivery_id" => delivery.id})

      assert_received {:webhook_delivered, %{url: url}}
      assert url == "https://example.com/webhook"
    end

    test "body is valid JSON containing the payload", %{delivery: delivery} do
      Process.put(:webhook_stub_result, {:ok, 200})
      perform_job(Worker, %{"delivery_id" => delivery.id})

      assert_received {:webhook_delivered, %{body: body}}
      decoded = Jason.decode!(body)
      assert decoded["type"] == "session.completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Delivery.Worker — failure paths
  # ---------------------------------------------------------------------------

  describe "Delivery.Worker non-2xx response" do
    setup do
      user = user_fixture()
      org = organization_fixture(user)
      endpoint = endpoint_fixture(org.id)
      event = event_fixture(org.id)
      Webhooks.dispatch(event)
      delivery = Repo.one!(from d in Delivery, where: d.endpoint_id == ^endpoint.id)
      %{delivery: delivery}
    end

    test "returns {:error, _}, delivery stays :pending on non-final attempt", %{
      delivery: delivery
    } do
      Process.put(:webhook_stub_result, {:ok, 500})

      assert {:error, "HTTP 500"} = perform_job(Worker, %{"delivery_id" => delivery.id})

      updated = Repo.reload!(delivery)
      assert updated.status == :pending
      assert updated.attempts == 1
      assert updated.response_status == 500
      assert updated.last_error == "HTTP 500"
    end

    test "marks delivery :failed on the final attempt (attempt == max_attempts)", %{
      delivery: delivery
    } do
      Process.put(:webhook_stub_result, {:ok, 500})

      assert {:error, _} =
               perform_job(Worker, %{"delivery_id" => delivery.id},
                 attempt: 5,
                 max_attempts: 5
               )

      updated = Repo.reload!(delivery)
      assert updated.status == :failed
    end
  end

  describe "Delivery.Worker transport error" do
    setup do
      user = user_fixture()
      org = organization_fixture(user)
      endpoint = endpoint_fixture(org.id)
      event = event_fixture(org.id)
      Webhooks.dispatch(event)
      delivery = Repo.one!(from d in Delivery, where: d.endpoint_id == ^endpoint.id)
      %{delivery: delivery}
    end

    test "returns {:error, _} and records last_error on transport failure", %{delivery: delivery} do
      Process.put(:webhook_stub_result, {:error, :timeout})

      assert {:error, _reason} = perform_job(Worker, %{"delivery_id" => delivery.id})

      updated = Repo.reload!(delivery)
      assert updated.status == :pending
      assert updated.last_error =~ "timeout"
    end
  end

  # ---------------------------------------------------------------------------
  # redeliver/2
  # ---------------------------------------------------------------------------

  describe "redeliver/2" do
    setup do
      user = user_fixture()
      scope = user_scope_fixture(user)
      org = organization_fixture(user)
      endpoint = endpoint_fixture(org.id)
      event = event_fixture(org.id)
      Webhooks.dispatch(event)
      delivery = Repo.one!(from d in Delivery, where: d.endpoint_id == ^endpoint.id)
      %{delivery: delivery, scope: scope}
    end

    test "redeliver is idempotent — does not queue duplicate jobs for the same delivery",
         %{delivery: delivery, scope: scope} do
      assert {:ok, _} = Webhooks.redeliver(delivery, scope)
      assert {:ok, _} = Webhooks.redeliver(delivery, scope)

      assert length(all_enqueued(worker: Worker)) == 1
    end

    test "redeliver resets delivery status to :pending", %{delivery: delivery, scope: scope} do
      assert {:ok, updated} = Webhooks.redeliver(delivery, scope)
      assert updated.status == :pending
    end

    test "redeliver returns :unauthorized for non-admin user", %{delivery: delivery} do
      other_user = user_fixture()
      other_scope = user_scope_fixture(other_user)

      assert {:error, :unauthorized} = Webhooks.redeliver(delivery, other_scope)
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end: Events.emit → Webhooks.dispatch → enqueued job
  # ---------------------------------------------------------------------------

  describe "Events.emit/2 end-to-end" do
    test "emitting an event enqueues a Worker job for matching endpoints" do
      user = user_fixture()
      org = organization_fixture(user)
      _endpoint = endpoint_fixture(org.id)

      assert :ok =
               Events.emit(:"session.completed", %{
                 organization_id: org.id,
                 resource: %{"type" => "session", "id" => Ecto.UUID.generate()},
                 data: %{"status" => "complete"}
               })

      assert_enqueued(worker: Worker)
    end

    test "emitting an event with no matching endpoints enqueues nothing" do
      user = user_fixture()
      org = organization_fixture(user)
      # No endpoint for this org

      assert :ok =
               Events.emit(:"session.completed", %{
                 organization_id: org.id,
                 resource: %{"type" => "session", "id" => Ecto.UUID.generate()},
                 data: %{}
               })

      refute_enqueued(worker: Worker)
    end
  end
end
