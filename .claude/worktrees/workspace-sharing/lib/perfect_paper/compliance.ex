defmodule PerfectPaper.Compliance do
  @moduledoc """
  Privacy & regulatory compliance — the public API and sole boundary for
  cookie-consent decisions.

  This context is a pure functional core: it has no `Repo`/IO boundary because
  consent is stored in a signed first-party cookie rather than a table. The web
  layer reads/writes that cookie; this module owns the rules — the default
  posture per region, decision validation (through an `Ecto.Changeset`), and the
  cookie encode/decode shape.

  ## Regional posture

  Consent is opt-in (default deny) everywhere except the United States, where the
  prevailing regime is opt-out. So a US visitor starts with analytics/marketing
  granted; everyone else — the EU/EEA, the UK, Canada, and any unknown origin —
  starts fully denied until they choose. Region is determined upstream from
  Cloudflare's `CF-IPCountry` header.

  ## Google Consent Mode v2

  When a GTM container is configured (`:gtm_container_id`), the web layer loads it
  behind Consent Mode v2 so Google's tags stay dormant until the matching category
  is granted. With no container configured the consent signals are still emitted,
  keeping the surface ready for analytics without firing anything today.
  """

  alias PerfectPaper.Compliance.{CookieConsent, DsarRequest, Notifier}

  @doc """
  The visitor's country (ISO-3166 alpha-2) from Cloudflare's `CF-IPCountry`
  header, or `nil` when absent/unknown (`""` / `"XX"`). The single shared reader
  for consent defaults and regional pricing — callers must not re-parse the
  header themselves.
  """
  @spec country_from_conn(Plug.Conn.t()) :: String.t() | nil
  def country_from_conn(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "cf-ipcountry") do
      [value | _] when value not in ["", "XX"] -> value
      _ -> nil
    end
  end

  # Bump when the set/meaning of categories changes — stored decisions on an
  # older version are treated as undecided so the visitor is re-prompted.
  @consent_version 1

  @cookie_name "pp_consent"

  # 180 days. Re-prompting twice a year is a reasonable consent refresh cadence.
  @cookie_max_age 60 * 60 * 24 * 180

  @doc "The cookie name holding the consent decision."
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie_name

  @doc "The current consent schema version."
  @spec consent_version() :: integer()
  def consent_version, do: @consent_version

  @doc "Consent cookie lifetime, in seconds."
  @spec cookie_max_age() :: integer()
  def cookie_max_age, do: @cookie_max_age

  @doc """
  The configured Google Tag Manager container id, or `nil` when GTM is not wired
  up. Configure via `config :perfect_paper, :gtm_container_id, \"GTM-XXXXXXX\"`.
  """
  @spec gtm_container_id() :: String.t() | nil
  def gtm_container_id, do: Application.get_env(:perfect_paper, :gtm_container_id)

  @doc """
  The pre-decision default posture for a visitor from `country` (an ISO 3166-1
  alpha-2 code, or `nil`/unknown). US starts granted; everyone else starts denied.
  """
  @spec default_consent(String.t() | nil) :: CookieConsent.t()
  def default_consent(country) do
    granted = united_states?(country)

    %CookieConsent{
      essential: true,
      analytics: granted,
      marketing: granted,
      version: @consent_version,
      region: country
    }
  end

  @doc """
  Builds a validated consent decision from a visitor's action.

  Accepts `:accept_all`, `:reject_all`, or a params map of category booleans
  (`%{"analytics" => "true"}`). `essential` is always forced on. Pass `:region`
  in `opts` to stamp the originating country.
  """
  @spec build_consent(:accept_all | :reject_all | map(), keyword()) ::
          {:ok, CookieConsent.t()} | {:error, Ecto.Changeset.t()}
  def build_consent(decision, opts \\ []) do
    base = %{
      version: @consent_version,
      region: Keyword.get(opts, :region),
      decided_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    attrs =
      case decision do
        :accept_all ->
          Map.merge(base, %{analytics: true, marketing: true})

        :reject_all ->
          Map.merge(base, %{analytics: false, marketing: false})

        params when is_map(params) ->
          Map.merge(base, %{
            analytics: truthy(Map.get(params, "analytics", Map.get(params, :analytics))),
            marketing: truthy(Map.get(params, "marketing", Map.get(params, :marketing)))
          })
      end

    %CookieConsent{}
    |> CookieConsent.changeset(attrs)
    |> Ecto.Changeset.apply_action(:insert)
  end

  @doc """
  The plain map stored in the consent cookie. Keys are strings so the value
  survives JSON-ish round-tripping through the cookie store.
  """
  @spec encode_cookie(CookieConsent.t()) :: map()
  def encode_cookie(%CookieConsent{} = consent) do
    %{
      "version" => consent.version,
      "analytics" => consent.analytics,
      "marketing" => consent.marketing,
      "region" => consent.region,
      "decided_at" => consent.decided_at && DateTime.to_iso8601(consent.decided_at)
    }
  end

  @doc """
  Decodes a stored cookie value back into a decision. Returns `nil` when there is
  no cookie or the stored version is stale (so the visitor is re-prompted).
  `country` falls back the cookie's own stored region.
  """
  @spec consent_from_cookie(map() | nil, String.t() | nil) :: CookieConsent.t() | nil
  def consent_from_cookie(nil, _country), do: nil

  def consent_from_cookie(%{} = map, country) do
    version = get(map, "version")

    if version == @consent_version do
      %CookieConsent{
        essential: true,
        analytics: truthy(get(map, "analytics")),
        marketing: truthy(get(map, "marketing")),
        version: version,
        region: get(map, "region") || country,
        decided_at: parse_decided_at(get(map, "decided_at"))
      }
    end
  end

  @eea ~w(AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE IS LI NO)
  @doc "True if the country is in the EU/EEA (for Omnibus struck-price suppression)."
  @spec eea?(String.t() | nil) :: boolean()
  def eea?(code) when is_binary(code), do: String.upcase(code) in @eea
  def eea?(_), do: false

  # --- helpers ---

  defp united_states?(country) when is_binary(country), do: String.upcase(country) == "US"
  defp united_states?(_), do: false

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy("on"), do: true
  defp truthy(_), do: false

  defp get(map, key), do: Map.get(map, key, Map.get(map, String.to_existing_atom(key)))

  defp parse_decided_at(nil), do: nil

  defp parse_decided_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_decided_at(%DateTime{} = dt), do: dt

  # ── DSAR (Data Subject Access Request) ───────────────────────────────────────

  @doc "Returns a fresh empty changeset for the DSAR form."
  @spec new_dsar_request() :: Ecto.Changeset.t()
  def new_dsar_request, do: DsarRequest.changeset(%DsarRequest{}, %{})

  @doc """
  Validates and submits a DSAR request. On success, notifies the privacy team
  and returns `{:ok, %DsarRequest{}}`. Mailer failures are swallowed so a
  transient email error does not block the user's confirmation.
  """
  @spec submit_dsar(map()) :: {:ok, DsarRequest.t()} | {:error, Ecto.Changeset.t()}
  def submit_dsar(attrs) do
    changeset = DsarRequest.changeset(%DsarRequest{}, attrs)

    with {:ok, dsar} <- Ecto.Changeset.apply_action(changeset, :insert) do
      _ = Notifier.deliver_dsar_notification(dsar)
      {:ok, dsar}
    end
  end
end
