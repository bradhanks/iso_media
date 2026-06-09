defmodule PerfectPaper.Webhooks.Endpoint do
  @moduledoc """
  An org-scoped webhook endpoint: a URL to which PerfectPaper delivers events,
  filtered to the event types the subscriber requested.

  Secrets are stored as-is (hashing/rotation is a future concern). URL validation
  performs a basic SSRF guard: only http/https are allowed and obviously-private
  hosts are rejected.

  # TODO(webhooks): deeper SSRF allow-listing / egress proxy.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias PerfectPaper.Events.Event

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          organization_id: Ecto.UUID.t() | nil,
          url: String.t() | nil,
          secret: String.t() | nil,
          event_types: [String.t()],
          description: String.t() | nil,
          active: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "webhook_endpoints" do
    field :organization_id, :binary_id
    field :url, :string
    field :secret, :string
    field :event_types, {:array, :string}, default: []
    field :description, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @create_fields [:organization_id, :url, :secret, :event_types, :description, :active]
  @required_fields [:organization_id, :url, :secret]

  @doc """
  Changeset for creating a new webhook endpoint.
  Casts all fields; requires organization_id, url, and secret.
  Validates url scheme and SSRF-guarded host, and that every entry in
  event_types is a known PerfectPaper event type.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = endpoint, attrs) do
    endpoint
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
    |> validate_url()
    |> validate_event_types()
  end

  @doc """
  Changeset for updating an existing webhook endpoint.
  Does NOT allow changing the secret or organization_id.
  Validates url and event_types if provided.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = endpoint, attrs) do
    endpoint
    |> cast(attrs, [:url, :event_types, :description, :active])
    |> validate_url()
    |> validate_event_types()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @allowed_schemes ["http", "https"]
  @blocked_hosts ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
  @private_prefixes [
    "10.",
    "192.168.",
    "172.16.",
    "172.17.",
    "172.18.",
    "172.19.",
    "172.20.",
    "172.21.",
    "172.22.",
    "172.23.",
    "172.24.",
    "172.25.",
    "172.26.",
    "172.27.",
    "172.28.",
    "172.29.",
    "172.30.",
    "172.31."
  ]

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}} ->
          cond do
            scheme not in @allowed_schemes ->
              [{:url, "must use http or https scheme"}]

            is_nil(host) or host == "" ->
              [{:url, "must include a valid host"}]

            host in @blocked_hosts ->
              [{:url, "private or loopback hosts are not allowed"}]

            host == "[::1]" ->
              [{:url, "private or loopback hosts are not allowed"}]

            # Strip brackets from IPv6 literal for prefix matching
            private_host?(strip_brackets(host)) ->
              [{:url, "private or loopback hosts are not allowed"}]

            true ->
              []
          end

        {:error, _} ->
          [{:url, "is not a valid URL"}]
      end
    end)
  end

  defp strip_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp strip_brackets(host), do: host

  defp private_host?(host) do
    Enum.any?(@private_prefixes, &String.starts_with?(host, &1))
  end

  @valid_event_types Event.types() |> Enum.map(&to_string/1)

  defp validate_event_types(changeset) do
    validate_change(changeset, :event_types, fn :event_types, types ->
      invalid = Enum.reject(types, &(&1 in @valid_event_types))

      if invalid == [] do
        []
      else
        [{:event_types, "contains unknown event types: #{Enum.join(invalid, ", ")}"}]
      end
    end)
  end
end
