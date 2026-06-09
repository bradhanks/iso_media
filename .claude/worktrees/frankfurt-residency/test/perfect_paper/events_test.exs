defmodule PerfectPaper.EventsTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Events

  test "emit validates and broadcasts to subscribers of the type" do
    Events.subscribe(:"session.completed")
    org_id = Ecto.UUID.generate()

    assert :ok =
             Events.emit(:"session.completed", %{
               organization_id: org_id,
               resource: %{type: :session, id: Ecto.UUID.generate()},
               data: %{status: "complete"}
             })

    assert_receive {:event,
                    %PerfectPaper.Events.Event{
                      type: :"session.completed",
                      organization_id: ^org_id
                    }}
  end

  test "emit rejects an unknown event type" do
    assert {:error, %Ecto.Changeset{}} = Events.emit(:"bogus.event", %{})
  end
end
