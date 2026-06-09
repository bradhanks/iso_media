defmodule PerfectPaper.Webhooks.DeliveryTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Webhooks.Delivery

  @valid_attrs %{
    endpoint_id: Ecto.UUID.generate(),
    event_type: "session.completed"
  }

  describe "create_changeset/2" do
    test "accepts a valid pending delivery" do
      changeset = Delivery.create_changeset(%Delivery{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires endpoint_id" do
      attrs = Map.delete(@valid_attrs, :endpoint_id)
      errors = errors_on(Delivery.create_changeset(%Delivery{}, attrs))
      assert "can't be blank" in errors.endpoint_id
    end

    test "requires event_type" do
      attrs = Map.delete(@valid_attrs, :event_type)
      errors = errors_on(Delivery.create_changeset(%Delivery{}, attrs))
      assert "can't be blank" in errors.event_type
    end

    test "accepts optional payload" do
      attrs = Map.put(@valid_attrs, :payload, %{"key" => "value"})
      changeset = Delivery.create_changeset(%Delivery{}, attrs)
      assert changeset.valid?
    end

    test "accepts optional event_id" do
      attrs = Map.put(@valid_attrs, :event_id, Ecto.UUID.generate())
      changeset = Delivery.create_changeset(%Delivery{}, attrs)
      assert changeset.valid?
    end
  end

  describe "attempt_changeset/2" do
    test "updates status, attempts, and response_status" do
      delivery = %Delivery{
        endpoint_id: Ecto.UUID.generate(),
        event_type: "session.completed",
        status: :pending,
        attempts: 0,
        payload: %{}
      }

      changeset =
        Delivery.attempt_changeset(delivery, %{
          status: :delivered,
          attempts: 1,
          response_status: 200,
          delivered_at: DateTime.utc_now()
        })

      assert changeset.valid?
      assert changeset.changes.status == :delivered
      assert changeset.changes.attempts == 1
      assert changeset.changes.response_status == 200
    end

    test "updates status to failed with last_error" do
      delivery = %Delivery{
        endpoint_id: Ecto.UUID.generate(),
        event_type: "session.completed",
        status: :pending,
        attempts: 0,
        payload: %{}
      }

      changeset =
        Delivery.attempt_changeset(delivery, %{
          status: :failed,
          attempts: 3,
          last_error: "Connection refused"
        })

      assert changeset.valid?
      assert changeset.changes.status == :failed
      assert changeset.changes.last_error == "Connection refused"
    end
  end
end
