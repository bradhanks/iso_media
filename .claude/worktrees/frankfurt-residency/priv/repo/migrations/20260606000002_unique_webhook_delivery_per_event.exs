defmodule PerfectPaper.Repo.Migrations.UniqueWebhookDeliveryPerEvent do
  use Ecto.Migration

  @moduledoc """
  At-least-once webhook delivery must not double-deliver: a replayed dispatch of
  the same domain event to the same endpoint should be a no-op. A partial unique
  index on (endpoint_id, event_id) makes the delivery insert idempotent.
  """

  def change do
    create unique_index(:webhook_deliveries, [:endpoint_id, :event_id],
             where: "event_id IS NOT NULL",
             name: :webhook_deliveries_endpoint_event_uidx
           )
  end
end
