defmodule PerfectPaper.Events do
  @moduledoc """
  The domain event bus. Contexts call `emit/2` AFTER their DB transaction commits
  (NEVER inside an Ecto.Multi — PubSub broadcast is synchronous, so emitting inside
  the transaction would let an in-process subscriber read the resource before the
  originating transaction commits). Each event is broadcast on PubSub (in-process
  consumers: realtime, campaigns) and (Task 4) handed to Webhooks.dispatch/1 for
  durable fan-out.
  """
  alias PerfectPaper.Events.Event

  @spec topic(atom()) :: String.t()
  def topic(type), do: "events:#{type}"

  @spec subscribe(atom()) :: :ok | {:error, term()}
  def subscribe(type), do: Phoenix.PubSub.subscribe(PerfectPaper.PubSub, topic(type))

  @doc "Builds, validates, and publishes an event. Call AFTER the originating transaction commits."
  @spec emit(atom(), map()) :: :ok | {:error, Ecto.Changeset.t()}
  def emit(type, attrs) do
    attrs =
      attrs
      |> Map.put(:type, type)
      |> Map.put_new(:id, Ecto.UUID.generate())
      |> Map.put_new(:occurred_at, DateTime.utc_now())

    case Event.changeset(attrs) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, event} -> publish(event)
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Publishes an already-built event: PubSub broadcast + durable webhook fan-out."
  @spec publish(Event.t()) :: :ok
  def publish(%Event{} = event) do
    Phoenix.PubSub.broadcast(PerfectPaper.PubSub, topic(event.type), {:event, event})
    PerfectPaper.Webhooks.dispatch(event)
    :ok
  end
end
