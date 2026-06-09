defmodule PerfectPaper.Webhooks do
  @moduledoc """
  Org-scoped webhook subscriptions and durable, signed delivery.

  This is the only `Repo`/IO boundary for webhook data and outbound delivery.
  Web layer and other contexts (notably `Events`) call into here — never into
  submodules or `Repo` directly.

  ## Delivery guarantees

  `dispatch/1` fans an event out to all matching active endpoints for the
  event's organization. For each match it inserts a `Delivery` row **and**
  enqueues an Oban job in one `Repo.transaction` — at-least-once semantics:
  there is never a job without a row or a row without a job.

  The Oban worker (`Webhooks.Delivery.Worker`) performs the signed HTTP POST
  and retries up to `max_attempts` times on failure.
  """

  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.Organizations
  alias PerfectPaper.Organizations.Organization
  alias PerfectPaper.Accounts.Scope
  alias PerfectPaper.Events.Event
  alias PerfectPaper.Webhooks.{Delivery, Endpoint}

  @doc """
  Fan out an event to all matching active org endpoints.

  For each matching endpoint, inserts a pending `Delivery` and enqueues
  `Delivery.Worker` atomically in a single `Repo.transaction`.

  Returns `:ok` immediately (fire-and-forget enqueue — the worker handles
  delivery, retries, and status tracking).

  Events with no `organization_id` are silently dropped (no endpoint lookup
  is possible).
  """
  @spec dispatch(Event.t()) :: :ok
  def dispatch(%Event{organization_id: nil}), do: :ok

  def dispatch(%Event{} = event) do
    type = to_string(event.type)

    for endpoint <- matching_endpoints(event.organization_id, type) do
      payload = build_payload(event)

      Repo.transaction(fn ->
        case %Delivery{}
             |> Delivery.create_changeset(%{
               endpoint_id: endpoint.id,
               event_type: type,
               event_id: event.id,
               payload: payload
             })
             |> Repo.insert() do
          {:ok, delivery} ->
            {:ok, _job} =
              %{delivery_id: delivery.id}
              |> PerfectPaper.Webhooks.Delivery.Worker.new()
              |> Oban.insert()

            delivery

          # A delivery for this (endpoint, event) already exists — a replayed
          # dispatch. Idempotent no-op: don't enqueue a duplicate send.
          {:error, %Ecto.Changeset{}} ->
            :duplicate
        end
      end)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Management API (CRUD + rotate_secret + redeliver) — org-admin gated
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new webhook endpoint for `org`.

  Generates a cryptographically random secret and stores it on the endpoint.
  The secret is returned in the `{:ok, endpoint}` tuple (the only time it is
  visible in plaintext) — callers should present it to the user immediately.

  Returns `{:error, :unauthorized}` if `scope`'s user is not an owner or
  admin of `org`.
  """
  @spec create_endpoint(Organization.t(), Scope.t(), map()) ::
          {:ok, Endpoint.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_endpoint(%Organization{} = org, %Scope{user: %{id: uid}}, attrs) do
    if Organizations.admin?(org, uid) do
      secret = generate_secret()

      %Endpoint{}
      |> Endpoint.create_changeset(
        attrs
        |> stringify_keys()
        |> Map.merge(%{"organization_id" => org.id, "secret" => secret})
      )
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns all webhook endpoints belonging to `org`.

  Returns `{:error, :unauthorized}` if the caller is not an org owner/admin.
  """
  @spec list_endpoints(Organization.t(), Scope.t()) ::
          {:ok, [Endpoint.t()]} | {:error, :unauthorized}
  def list_endpoints(%Organization{} = org, %Scope{user: %{id: uid}}) do
    if Organizations.admin?(org, uid) do
      endpoints =
        Repo.all(
          from e in Endpoint,
            where: e.organization_id == ^org.id,
            order_by: [asc: e.inserted_at]
        )

      {:ok, endpoints}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Loads a single webhook endpoint by `id`.

  Returns `{:error, :not_found}` when the id does not exist.
  Returns `{:error, :unauthorized}` when the caller is not an admin of the
  endpoint's organization.
  """
  @spec get_endpoint(Ecto.UUID.t(), Scope.t()) ::
          {:ok, Endpoint.t()} | {:error, :not_found | :unauthorized}
  def get_endpoint(id, %Scope{user: %{id: uid}}) do
    cond do
      not PerfectPaper.UUID.valid?(id) ->
        {:error, :not_found}

      endpoint = Repo.get(Endpoint, id) ->
        if Organizations.admin?(endpoint.organization_id, uid),
          do: {:ok, endpoint},
          else: {:error, :unauthorized}

      true ->
        {:error, :not_found}
    end
  end

  @doc """
  Updates url, event_types, description, or active flag on an endpoint.

  Secret and organization_id cannot be changed via this function.
  Returns `{:error, :unauthorized}` if the caller is not an org admin.
  """
  @spec update_endpoint(Endpoint.t(), Scope.t(), map()) ::
          {:ok, Endpoint.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def update_endpoint(%Endpoint{} = endpoint, %Scope{user: %{id: uid}}, attrs) do
    if Organizations.admin?(endpoint.organization_id, uid) do
      endpoint
      |> Endpoint.update_changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes a webhook endpoint (and all its delivery records, via cascade).

  Returns `{:error, :unauthorized}` if the caller is not an org admin.
  """
  @spec delete_endpoint(Endpoint.t(), Scope.t()) ::
          {:ok, Endpoint.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def delete_endpoint(%Endpoint{} = endpoint, %Scope{user: %{id: uid}}) do
    if Organizations.admin?(endpoint.organization_id, uid) do
      Repo.delete(endpoint)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Rotates the signing secret for an endpoint.

  Generates a new cryptographically random secret and persists it.
  The new secret is returned in the `{:ok, endpoint}` tuple — present it to the
  user immediately as it will not be retrievable in plaintext later.

  Returns `{:error, :unauthorized}` if the caller is not an org admin.
  """
  @spec rotate_secret(Endpoint.t(), Scope.t()) ::
          {:ok, Endpoint.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def rotate_secret(%Endpoint{} = endpoint, %Scope{user: %{id: uid}}) do
    if Organizations.admin?(endpoint.organization_id, uid) do
      new_secret = generate_secret()

      endpoint
      |> Ecto.Changeset.change(%{secret: new_secret})
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns the delivery log for an endpoint, newest first.

  `opts` accepts `limit:` (default 50).

  Returns `{:error, :unauthorized}` if the caller is not an org admin.
  """
  @spec list_deliveries(Endpoint.t(), Scope.t(), keyword()) ::
          {:ok, [Delivery.t()]} | {:error, :unauthorized}
  def list_deliveries(%Endpoint{} = endpoint, %Scope{user: %{id: uid}}, opts \\ []) do
    if Organizations.admin?(endpoint.organization_id, uid) do
      limit = Keyword.get(opts, :limit, 50)

      deliveries =
        Repo.all(
          from d in Delivery,
            where: d.endpoint_id == ^endpoint.id,
            order_by: [desc: d.inserted_at],
            limit: ^limit
        )

      {:ok, deliveries}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Loads a single delivery by `id`.

  Returns `{:error, :not_found}` when the id does not exist.
  Returns `{:error, :unauthorized}` when the caller is not an admin of the
  delivery's endpoint's organization.
  """
  @spec get_delivery(Ecto.UUID.t(), Scope.t()) ::
          {:ok, Delivery.t()} | {:error, :not_found | :unauthorized}
  def get_delivery(id, %Scope{user: %{id: uid}}) do
    case Repo.get(Delivery, id) do
      nil ->
        {:error, :not_found}

      %Delivery{} = delivery ->
        endpoint = Repo.get!(Endpoint, delivery.endpoint_id)

        if Organizations.admin?(endpoint.organization_id, uid) do
          {:ok, delivery}
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Re-enqueues a failed or pending delivery for immediate retry.

  Resets the delivery status to `:pending` and inserts a fresh Oban job.
  The delivery's attempt counter is preserved (for auditing); only the status
  is reset.

  Authorization is gated on the delivery's endpoint's organization — the caller
  must be an admin of that org.
  Returns `{:error, :unauthorized}` if not.
  """
  @spec redeliver(Delivery.t(), Scope.t()) ::
          {:ok, Delivery.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def redeliver(%Delivery{} = delivery, %Scope{user: %{id: uid}}) do
    endpoint = Repo.get!(Endpoint, delivery.endpoint_id)

    if Organizations.admin?(endpoint.organization_id, uid) do
      Repo.transaction(fn ->
        {:ok, updated} =
          delivery
          |> Delivery.attempt_changeset(%{status: :pending})
          |> Repo.update()

        {:ok, _job} =
          %{delivery_id: delivery.id}
          |> PerfectPaper.Webhooks.Delivery.Worker.new(
            unique: [
              keys: [:delivery_id],
              states: [:available, :scheduled, :executing, :retryable]
            ]
          )
          |> Oban.insert()

        updated
      end)
    else
      {:error, :unauthorized}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Converts atom keys to strings so that merging context-supplied fields
  # (organization_id, secret) does not create a mixed-key map when `attrs`
  # arrives as a string-keyed map from a controller.
  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Signing secret. The `whsec_` prefix makes the contract unambiguous: it is an
  # OPAQUE token used verbatim as the HMAC-SHA256 key (Stripe-style) — the prefix
  # also means a receiver can't mistake the value for plain base64 and decode it,
  # which would break signature verification. See Delivery.Worker.compute_signature/3.
  @secret_prefix "whsec_"
  defp generate_secret,
    do: @secret_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @spec matching_endpoints(Ecto.UUID.t(), String.t()) :: [Endpoint.t()]
  defp matching_endpoints(org_id, type) do
    Repo.all(
      from e in Endpoint,
        where:
          e.organization_id == ^org_id and
            e.active == true and
            fragment("? = ANY(?)", ^type, e.event_types)
    )
  end

  @spec build_payload(Event.t()) :: map()
  defp build_payload(%Event{} = event) do
    %{
      "type" => to_string(event.type),
      "occurred_at" => event.occurred_at && DateTime.to_iso8601(event.occurred_at),
      "organization_id" => event.organization_id,
      "resource" => event.resource,
      "data" => event.data
      # TODO(webhooks): add links.self when a canonical resource URL helper exists.
    }
  end
end
