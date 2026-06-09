defmodule PerfectPaper.Webhooks.EndpointTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Webhooks.Endpoint

  @valid_attrs %{
    organization_id: Ecto.UUID.generate(),
    url: "https://example.com/hook",
    secret: "supersecretvalue",
    event_types: ["session.completed"]
  }

  describe "create_changeset/2" do
    test "accepts a valid endpoint" do
      changeset = Endpoint.create_changeset(%Endpoint{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires organization_id" do
      attrs = Map.delete(@valid_attrs, :organization_id)
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert "can't be blank" in errors.organization_id
    end

    test "requires url" do
      attrs = Map.delete(@valid_attrs, :url)
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert "can't be blank" in errors.url
    end

    test "requires secret" do
      attrs = Map.delete(@valid_attrs, :secret)
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert "can't be blank" in errors.secret
    end

    test "rejects ftp:// url" do
      attrs = Map.put(@valid_attrs, :url, "ftp://example.com/files")
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert errors[:url] != nil
    end

    test "rejects localhost url" do
      attrs = Map.put(@valid_attrs, :url, "http://localhost/hook")
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert errors[:url] != nil
    end

    test "rejects 127.0.0.1 url" do
      attrs = Map.put(@valid_attrs, :url, "http://127.0.0.1/hook")
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert errors[:url] != nil
    end

    test "rejects 0.0.0.0 url" do
      attrs = Map.put(@valid_attrs, :url, "http://0.0.0.0/hook")
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert errors[:url] != nil
    end

    test "rejects ::1 (IPv6 loopback) url" do
      attrs = Map.put(@valid_attrs, :url, "http://[::1]/hook")
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert errors[:url] != nil
    end

    test "rejects 10.x private range url" do
      attrs = Map.put(@valid_attrs, :url, "http://10.0.0.1/hook")
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert errors[:url] != nil
    end

    test "rejects 192.168.x private range url" do
      attrs = Map.put(@valid_attrs, :url, "http://192.168.1.1/hook")
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert errors[:url] != nil
    end

    test "rejects 172.16.x private range url" do
      attrs = Map.put(@valid_attrs, :url, "http://172.16.0.1/hook")
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert errors[:url] != nil
    end

    test "rejects unknown event type in event_types" do
      attrs = Map.put(@valid_attrs, :event_types, ["bogus.event"])
      errors = errors_on(Endpoint.create_changeset(%Endpoint{}, attrs))
      assert errors[:event_types] != nil
    end

    test "accepts all valid event types" do
      valid_types = Enum.map(PerfectPaper.Events.Event.types(), &to_string/1)
      attrs = Map.put(@valid_attrs, :event_types, valid_types)
      changeset = Endpoint.create_changeset(%Endpoint{}, attrs)
      assert changeset.valid?
    end

    test "accepts empty event_types list" do
      attrs = Map.put(@valid_attrs, :event_types, [])
      changeset = Endpoint.create_changeset(%Endpoint{}, attrs)
      assert changeset.valid?
    end
  end

  describe "update_changeset/2" do
    test "accepts valid update attrs" do
      endpoint = %Endpoint{
        organization_id: Ecto.UUID.generate(),
        url: "https://example.com/hook",
        secret: "oldsecret",
        event_types: ["session.completed"],
        active: true
      }

      changeset =
        Endpoint.update_changeset(endpoint, %{
          url: "https://example.com/hook2",
          event_types: ["comment.addressed"],
          description: "Updated",
          active: false
        })

      assert changeset.valid?
    end

    test "does not cast secret in update" do
      endpoint = %Endpoint{
        organization_id: Ecto.UUID.generate(),
        url: "https://example.com/hook",
        secret: "oldsecret",
        event_types: [],
        active: true
      }

      changeset = Endpoint.update_changeset(endpoint, %{secret: "newsecret"})
      refute Map.has_key?(changeset.changes, :secret)
    end

    test "does not cast organization_id in update" do
      endpoint = %Endpoint{
        organization_id: Ecto.UUID.generate(),
        url: "https://example.com/hook",
        secret: "oldsecret",
        event_types: [],
        active: true
      }

      changeset = Endpoint.update_changeset(endpoint, %{organization_id: Ecto.UUID.generate()})
      refute Map.has_key?(changeset.changes, :organization_id)
    end

    test "rejects invalid url in update" do
      endpoint = %Endpoint{
        organization_id: Ecto.UUID.generate(),
        url: "https://example.com/hook",
        secret: "oldsecret",
        event_types: [],
        active: true
      }

      errors = errors_on(Endpoint.update_changeset(endpoint, %{url: "ftp://example.com"}))
      assert errors[:url] != nil
    end

    test "rejects unknown event type in update" do
      endpoint = %Endpoint{
        organization_id: Ecto.UUID.generate(),
        url: "https://example.com/hook",
        secret: "oldsecret",
        event_types: [],
        active: true
      }

      errors =
        errors_on(Endpoint.update_changeset(endpoint, %{event_types: ["not.a.type"]}))

      assert errors[:event_types] != nil
    end
  end
end
