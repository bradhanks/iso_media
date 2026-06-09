defmodule PerfectPaperWeb.WebhooksLive do
  @moduledoc """
  Org-admin webhook management: list endpoints, create, delete, view the
  delivery log, and redeliver failed deliveries.

  Mount gates on org-admin status: users who do not own or administer any
  organization are redirected away immediately.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Authz, Organizations, Webhooks}
  alias PerfectPaper.Events.Event

  @all_event_types Event.types() |> Enum.map(&to_string/1)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    scope = Authz.load_subject(user)

    case Organizations.admin_orgs(user.id) do
      [] ->
        socket =
          socket
          |> put_flash(:error, gettext("You must be an organisation admin to manage webhooks."))
          |> push_navigate(to: ~p"/new")

        {:ok, socket}

      [org | _] ->
        {:ok, endpoints} = Webhooks.list_endpoints(org, scope)

        {:ok,
         assign(socket,
           page_title: "Webhooks",
           org: org,
           scope: scope,
           endpoints: endpoints,
           # deliveries keyed by endpoint id
           deliveries: %{},
           # form state
           form_url: "",
           form_event_types: [],
           form_description: "",
           form_errors: %{},
           # one-time create secret shown as flash — not stored beyond that
           event_types_options: @all_event_types
         )}
    end
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("create", %{"endpoint" => params}, socket) do
    %{org: org, scope: scope} = socket.assigns

    url = Map.get(params, "url", "") |> String.trim()
    description = Map.get(params, "description", "") |> String.trim()

    event_types =
      params
      |> Map.get("event_types", "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    attrs = %{url: url, event_types: event_types, description: description}

    case Webhooks.create_endpoint(org, scope, attrs) do
      {:ok, endpoint} ->
        {:ok, endpoints} = Webhooks.list_endpoints(org, scope)

        socket =
          socket
          |> assign(
            endpoints: endpoints,
            form_url: "",
            form_event_types: [],
            form_description: "",
            form_errors: %{}
          )
          |> put_flash(
            :info,
            gettext("Endpoint created. Signing secret (shown once): %{secret}",
              secret: endpoint.secret
            )
          )

        {:noreply, socket}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to create endpoints."))}

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        {:noreply,
         assign(socket,
           form_errors: errors,
           form_url: url,
           form_description: description,
           form_event_types: event_types
         )}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{org: org, scope: scope} = socket.assigns

    with {:ok, endpoint} <- Webhooks.get_endpoint(id, scope),
         {:ok, _} <- Webhooks.delete_endpoint(endpoint, scope) do
      {:ok, endpoints} = Webhooks.list_endpoints(org, scope)

      {:noreply,
       socket
       |> assign(endpoints: endpoints)
       |> put_flash(:info, gettext("Endpoint deleted."))}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Endpoint not found."))}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to delete that endpoint."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete that endpoint."))}
    end
  end

  def handle_event("load_deliveries", %{"id" => endpoint_id}, socket) do
    scope = socket.assigns.scope

    with {:ok, endpoint} <- Webhooks.get_endpoint(endpoint_id, scope),
         {:ok, deliveries} <- Webhooks.list_deliveries(endpoint, scope, limit: 20) do
      updated = Map.put(socket.assigns.deliveries, endpoint_id, deliveries)
      {:noreply, assign(socket, deliveries: updated)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not load deliveries."))}
    end
  end

  def handle_event("redeliver", %{"id" => delivery_id}, socket) do
    scope = socket.assigns.scope

    with {:ok, delivery} <- Webhooks.get_delivery(delivery_id, scope),
         {:ok, _updated} <- Webhooks.redeliver(delivery, scope) do
      # Refresh deliveries for that endpoint
      endpoint_id = delivery.endpoint_id

      updated_deliveries =
        case Webhooks.get_endpoint(endpoint_id, scope) do
          {:ok, endpoint} ->
            case Webhooks.list_deliveries(endpoint, scope, limit: 20) do
              {:ok, ds} -> Map.put(socket.assigns.deliveries, endpoint_id, ds)
              _ -> socket.assigns.deliveries
            end

          _ ->
            socket.assigns.deliveries
        end

      {:noreply,
       socket
       |> assign(deliveries: updated_deliveries)
       |> put_flash(:info, gettext("Redelivery enqueued."))}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Delivery not found."))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not authorised to redeliver."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not redeliver."))}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp field_errors(errors, field) do
    Map.get(errors, field, [])
  end
end
