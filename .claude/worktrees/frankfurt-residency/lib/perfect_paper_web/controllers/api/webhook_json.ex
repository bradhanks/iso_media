defmodule PerfectPaperWeb.Api.WebhookJSON do
  @moduledoc "Renders webhook endpoints and deliveries as JSON for the REST API."

  alias PerfectPaper.Webhooks.{Delivery, Endpoint}

  @doc "Renders a list of endpoints (no secret)."
  def index(%{endpoints: endpoints}) do
    %{data: for(e <- endpoints, do: endpoint(e, false))}
  end

  @doc """
  Renders a single endpoint.

  Pass `include_secret: true` only for create and rotate_secret — the secret
  is never exposed in any other response.
  """
  def show(%{endpoint: endpoint, include_secret: true}), do: %{data: endpoint(endpoint, true)}
  def show(%{endpoint: endpoint}), do: %{data: endpoint(endpoint, false)}

  @doc "Renders a list of deliveries."
  def deliveries(%{deliveries: deliveries}) do
    %{data: for(d <- deliveries, do: delivery(d))}
  end

  defp endpoint(%Endpoint{} = e, include_secret) do
    base = %{
      id: e.id,
      url: e.url,
      event_types: e.event_types,
      description: e.description,
      active: e.active,
      inserted_at: e.inserted_at
    }

    if include_secret do
      Map.put(base, :secret, e.secret)
    else
      base
    end
  end

  defp delivery(%Delivery{} = d) do
    %{
      id: d.id,
      event_type: d.event_type,
      status: d.status,
      attempts: d.attempts,
      response_status: d.response_status,
      inserted_at: d.inserted_at,
      delivered_at: d.delivered_at
    }
  end
end
