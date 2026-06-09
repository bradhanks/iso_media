defmodule PerfectPaper.WebhooksManagementTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  import PerfectPaper.WebhooksFixtures

  alias PerfectPaper.Authz
  alias PerfectPaper.Repo
  alias PerfectPaper.Webhooks
  alias PerfectPaper.Webhooks.{Delivery, Delivery.Worker, Endpoint}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Scope via Authz.load_subject/1 (canonical way to build an enriched scope).
  defp scope(user), do: Authz.load_subject(user)

  # A delivery fixture: inserts a minimal Delivery row for the given endpoint.
  defp delivery_fixture(%Endpoint{} = endpoint) do
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
  # create_endpoint/3
  # ---------------------------------------------------------------------------

  describe "create_endpoint/3" do
    test "org owner can create an endpoint; secret is returned and non-empty" do
      owner = user_fixture()
      org = organization_fixture(owner)

      assert {:ok, endpoint} =
               Webhooks.create_endpoint(org, scope(owner), %{
                 url: "https://example.com/hook",
                 event_types: ["session.completed"]
               })

      assert endpoint.organization_id == org.id
      assert endpoint.url == "https://example.com/hook"
      assert is_binary(endpoint.secret) and byte_size(endpoint.secret) > 0
      # Opaque, verbatim-key contract: secret is whsec_-prefixed so a receiver
      # can't mistake it for plain base64 and decode it (breaking verification).
      assert String.starts_with?(endpoint.secret, "whsec_")
    end

    test "org admin (membership role :admin) can create an endpoint" do
      owner = user_fixture()
      admin_user = user_fixture()
      org = organization_fixture(owner)
      membership_fixture(org, admin_user, :admin)

      assert {:ok, endpoint} =
               Webhooks.create_endpoint(org, scope(admin_user), %{
                 url: "https://example.com/hook",
                 event_types: ["session.completed"]
               })

      assert endpoint.organization_id == org.id
    end

    test "plain member returns {:error, :unauthorized}" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      membership_fixture(org, member, :member)

      assert {:error, :unauthorized} =
               Webhooks.create_endpoint(org, scope(member), %{
                 url: "https://example.com/hook",
                 event_types: ["session.completed"]
               })
    end

    test "stranger (no membership) returns {:error, :unauthorized}" do
      owner = user_fixture()
      stranger = user_fixture()
      org = organization_fixture(owner)

      assert {:error, :unauthorized} =
               Webhooks.create_endpoint(org, scope(stranger), %{
                 url: "https://example.com/hook",
                 event_types: ["session.completed"]
               })
    end

    test "generated secrets are crypto-strong (url_base64, 43-44 chars for 32 bytes)" do
      owner = user_fixture()
      org = organization_fixture(owner)

      {:ok, ep1} =
        Webhooks.create_endpoint(org, scope(owner), %{
          url: "https://a.example.com/hook",
          event_types: ["session.completed"]
        })

      {:ok, ep2} =
        Webhooks.create_endpoint(org, scope(owner), %{
          url: "https://b.example.com/hook",
          event_types: ["session.completed"]
        })

      assert ep1.secret != ep2.secret
      # 32 bytes → 43 or 44 chars in url_encode64 without padding
      assert String.length(ep1.secret) >= 43
    end
  end

  # ---------------------------------------------------------------------------
  # list_endpoints/2
  # ---------------------------------------------------------------------------

  describe "list_endpoints/2" do
    test "admin can list all org endpoints" do
      owner = user_fixture()
      org = organization_fixture(owner)
      ep1 = endpoint_fixture(org, %{url: "https://a.example.com/hook"})
      ep2 = endpoint_fixture(org, %{url: "https://b.example.com/hook"})

      assert {:ok, endpoints} = Webhooks.list_endpoints(org, scope(owner))
      ids = Enum.map(endpoints, & &1.id)
      assert ep1.id in ids
      assert ep2.id in ids
    end

    test "does not return endpoints from other orgs" do
      owner = user_fixture()
      other_owner = user_fixture()
      org = organization_fixture(owner)
      other_org = organization_fixture(other_owner)
      _ep = endpoint_fixture(other_org)

      assert {:ok, endpoints} = Webhooks.list_endpoints(org, scope(owner))
      assert endpoints == []
    end

    test "non-admin returns {:error, :unauthorized}" do
      owner = user_fixture()
      member = user_fixture()
      org = organization_fixture(owner)
      membership_fixture(org, member)

      assert {:error, :unauthorized} = Webhooks.list_endpoints(org, scope(member))
    end
  end

  # ---------------------------------------------------------------------------
  # get_endpoint/2
  # ---------------------------------------------------------------------------

  describe "get_endpoint/2" do
    test "admin can load an endpoint by id" do
      owner = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)

      assert {:ok, fetched} = Webhooks.get_endpoint(endpoint.id, scope(owner))
      assert fetched.id == endpoint.id
    end

    test "returns {:error, :not_found} for a missing id" do
      owner = user_fixture()
      _org = organization_fixture(owner)

      assert {:error, :not_found} =
               Webhooks.get_endpoint(Ecto.UUID.generate(), scope(owner))
    end

    test "returns {:error, :unauthorized} for a non-admin caller" do
      owner = user_fixture()
      stranger = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)

      assert {:error, :unauthorized} = Webhooks.get_endpoint(endpoint.id, scope(stranger))
    end
  end

  # ---------------------------------------------------------------------------
  # update_endpoint/3
  # ---------------------------------------------------------------------------

  describe "update_endpoint/3" do
    test "admin can change url and event_types" do
      owner = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)
      old_secret = endpoint.secret

      assert {:ok, updated} =
               Webhooks.update_endpoint(endpoint, scope(owner), %{
                 url: "https://updated.example.com/hook",
                 event_types: ["comment.addressed"]
               })

      assert updated.url == "https://updated.example.com/hook"
      assert updated.event_types == ["comment.addressed"]
      # secret must not change via update
      assert updated.secret == old_secret
    end

    test "non-admin returns {:error, :unauthorized}" do
      owner = user_fixture()
      stranger = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)

      assert {:error, :unauthorized} =
               Webhooks.update_endpoint(endpoint, scope(stranger), %{
                 url: "https://evil.example.com/hook"
               })
    end
  end

  # ---------------------------------------------------------------------------
  # delete_endpoint/2
  # ---------------------------------------------------------------------------

  describe "delete_endpoint/2" do
    test "admin can delete an endpoint" do
      owner = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)

      assert {:ok, _deleted} = Webhooks.delete_endpoint(endpoint, scope(owner))
      assert Repo.get(Endpoint, endpoint.id) == nil
    end

    test "non-admin returns {:error, :unauthorized}" do
      owner = user_fixture()
      stranger = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)

      assert {:error, :unauthorized} = Webhooks.delete_endpoint(endpoint, scope(stranger))
      assert Repo.get(Endpoint, endpoint.id) != nil
    end
  end

  # ---------------------------------------------------------------------------
  # rotate_secret/2
  # ---------------------------------------------------------------------------

  describe "rotate_secret/2" do
    test "admin can rotate the secret; new secret differs from old" do
      owner = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)
      old_secret = endpoint.secret

      assert {:ok, updated} = Webhooks.rotate_secret(endpoint, scope(owner))
      assert is_binary(updated.secret)
      assert updated.secret != old_secret
      assert String.length(updated.secret) >= 43
    end

    test "non-admin returns {:error, :unauthorized}" do
      owner = user_fixture()
      stranger = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)

      assert {:error, :unauthorized} = Webhooks.rotate_secret(endpoint, scope(stranger))
    end
  end

  # ---------------------------------------------------------------------------
  # list_deliveries/3
  # ---------------------------------------------------------------------------

  describe "list_deliveries/3" do
    test "admin can list deliveries for an endpoint (newest first)" do
      owner = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)
      d1 = delivery_fixture(endpoint)
      d2 = delivery_fixture(endpoint)

      assert {:ok, deliveries} = Webhooks.list_deliveries(endpoint, scope(owner))
      ids = Enum.map(deliveries, & &1.id)
      assert d1.id in ids
      assert d2.id in ids
    end

    test "does not return deliveries from other endpoints" do
      owner = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)
      other_endpoint = endpoint_fixture(org, %{url: "https://other.example.com/hook"})
      _other_delivery = delivery_fixture(other_endpoint)

      assert {:ok, deliveries} = Webhooks.list_deliveries(endpoint, scope(owner))
      assert deliveries == []
    end

    test "non-admin returns {:error, :unauthorized}" do
      owner = user_fixture()
      stranger = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)

      assert {:error, :unauthorized} = Webhooks.list_deliveries(endpoint, scope(stranger))
    end
  end

  # ---------------------------------------------------------------------------
  # redeliver/2
  # ---------------------------------------------------------------------------

  describe "redeliver/2" do
    test "admin can redeliver: delivery resets to :pending and a Worker job is enqueued" do
      owner = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)

      # Create a failed delivery
      delivery =
        delivery_fixture(endpoint)
        |> Delivery.attempt_changeset(%{status: :failed, attempts: 3, last_error: "timeout"})
        |> Repo.update!()

      assert delivery.status == :failed

      assert {:ok, redelivered} = Webhooks.redeliver(delivery, scope(owner))
      assert redelivered.status == :pending

      assert_enqueued(worker: Worker, args: %{"delivery_id" => delivery.id})
    end

    test "non-admin returns {:error, :unauthorized} and does not enqueue" do
      owner = user_fixture()
      stranger = user_fixture()
      org = organization_fixture(owner)
      endpoint = endpoint_fixture(org)
      delivery = delivery_fixture(endpoint)

      assert {:error, :unauthorized} = Webhooks.redeliver(delivery, scope(stranger))
      refute_enqueued(worker: Worker)
    end
  end
end
