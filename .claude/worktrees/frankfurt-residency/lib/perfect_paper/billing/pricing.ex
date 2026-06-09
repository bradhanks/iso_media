defmodule PerfectPaper.Billing.Pricing do
  @moduledoc """
  Pure, config-as-code cost-of-living (regional) + annual pricing math. No IO.

  All money is **integer cents** and every multiplier is an **integer basis
  point** (`10_000` = 100%) — there are no floats or `Decimal` in the hot path.
  Base list prices live in `Billing.Prices` (`list_cents`); this module reads
  them and applies band/volume/annual ratios, rounding **once at the end**.

  The pricers are keyed on a resolved **band**, not a country, so the same
  functions serve display (one country → its band) and the binding charge
  (two countries → the less-generous band, `resolve_band/2`).

  `round_psych/1` rounds to the nearest whole dollar; it is idempotent
  (`round_psych(round_psych(x)) == round_psych(x)`) and the pack pricer clamps
  so a displayed/charged price is **never above its list**.
  """

  alias PerfectPaper.Billing.Prices

  @basis 10_000

  # Floors (cents) — guard against degenerate amounts for future low-priced
  # products; at current prices they don't bind. Tunable here.
  @floor_monthly 500
  @floor_annual 5_000
  @floor_pack 999

  # Annual = 10 months charged for 12 served. Named so the idempotence/worked
  # tests reference the constant, not a magic number.
  @annual_months_charged 10
  @annual_months_served 12

  @type band_key :: :a | :b | :c | :d

  @bands [
    %{key: :a, bps: 10_000, label: "Standard"},
    %{key: :b, bps: 7_500, label: "Regional −25%"},
    %{key: :c, bps: 5_000, label: "Regional −50%"},
    %{key: :d, bps: 3_500, label: "Regional −65%"}
  ]

  # ISO-3166 alpha-2 → band, from the World Bank income-group list (applied
  # verbatim, no generosity overrides). Anything not listed defaults to Band A
  # (least discount — the safe default). Source + review cadence: see the spec.
  @band_b ~w(MX BR TR RU CN AR CO MY TH ZA RS)
  @band_c ~w(IN ID PH VN EG UA MA NG)
  @band_d ~w(ET CD UG AF MW NE TD SS BI MZ)

  @doc "All bands, with their basis-point multipliers."
  @spec bands() :: [%{key: band_key(), bps: pos_integer(), label: String.t()}]
  def bands, do: @bands

  @doc "Charged-months constant for an annual term (10 charged → 12 served)."
  @spec annual_months_charged() :: pos_integer()
  def annual_months_charged, do: @annual_months_charged

  # EU/EEA — for these visitors the *regional* struck-through "previous price" is
  # suppressed (EU Omnibus Directive: a struck reference price must be a genuine
  # prior selling price, not a synthetic regional list). The annual strike is a
  # real saving and stays. Most EU states are Band A anyway, so today this rarely
  # binds — it's a forward guard if the band map ever changes.
  @eu_eea ~w(AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT
             RO SK SI ES SE IS LI NO)

  @doc "Whether the country is in the EU/EEA (for the Omnibus strike-suppression guard)."
  @spec eu_country?(String.t() | nil) :: boolean()
  def eu_country?(country) when is_binary(country),
    do: String.upcase(String.trim(country)) in @eu_eea

  def eu_country?(_), do: false

  @doc "ISO-3166 alpha-2 country → band key. Unknown / nil → `:a` (safe, least discount)."
  @spec country_band(String.t() | nil) :: band_key()
  def country_band(country) when is_binary(country) do
    cc = String.upcase(String.trim(country))

    cond do
      cc in @band_d -> :d
      cc in @band_c -> :c
      cc in @band_b -> :b
      true -> :a
    end
  end

  def country_band(_), do: :a

  @doc """
  The band to bind a charge to given the IP country and the payment-method
  country: the **less generous** of the two (the larger `bps`). A single-country
  call resolves against itself. Arbitrage by spoofing one signal yields no
  benefit; the transaction always proceeds.
  """
  @spec resolve_band(String.t() | nil, String.t() | nil) :: band_key()
  def resolve_band(ip_country, payment_country) do
    a = country_band(ip_country)
    b = country_band(payment_country)
    if band_bps(a) >= band_bps(b), do: a, else: b
  end

  @doc """
  Subscription prices for a plan at a band, **both cadences** (the monthly/annual
  toggle is client-side, so both are server-rendered). `plan` is a `Prices`
  subscription map (uses its `list_cents` = Band-A monthly `M`).
  """
  @spec price_for(map(), band_key()) :: %{
          monthly_price: non_neg_integer(),
          monthly_list: non_neg_integer(),
          annual_price: non_neg_integer(),
          annual_list: non_neg_integer(),
          struck?: boolean(),
          band: band_key(),
          bps: pos_integer()
        }
  def price_for(%{list_cents: m}, band) do
    bps = band_bps(band)

    %{
      monthly_price: round_psych(max(ratio(m, bps), @floor_monthly)),
      monthly_list: m,
      annual_price: round_psych(max(ratio(m * @annual_months_charged, bps), @floor_annual)),
      annual_list: round_psych(ratio(m * @annual_months_served, bps)),
      # Regional strike on the monthly card only when the band discounts it; the
      # annual card always saves two months, so it strikes regardless.
      struck?: bps < @basis,
      band: band,
      bps: bps
    }
  end

  @doc """
  One-time pack price at a band. `pack` is a `Prices.credit_packs/0` entry (or
  `credit_single/0`) carrying `list_cents` `L` and `volume_bps`. Clamps so the
  result is never above list.
  """
  @spec pack_price_for(map(), band_key()) :: %{
          price: non_neg_integer(),
          list: non_neg_integer(),
          struck?: boolean(),
          volume_discount?: boolean(),
          band: band_key(),
          bps: pos_integer()
        }
  def pack_price_for(%{list_cents: l, volume_bps: v}, band) do
    bps = band_bps(band)
    # Single combined multiply (band × volume), divided once, then rounded once.
    raw = div(l * bps * v, @basis * @basis)
    price = min(round_psych(max(raw, @floor_pack)), l)

    %{
      price: price,
      list: l,
      struck?: price < l,
      volume_discount?: v < @basis,
      band: band,
      bps: bps
    }
  end

  @doc "The inline single-credit (\"buy one more review\") price at a band."
  @spec unit_price_for(band_key()) :: map()
  def unit_price_for(band), do: pack_price_for(Prices.credit_single(), band)

  @doc """
  Round to the nearest whole dollar (psychological pricing). Pure and idempotent:
  the output is always a multiple of 100 cents, so re-applying is a no-op.
  """
  @spec round_psych(integer()) :: integer()
  def round_psych(cents) when is_integer(cents), do: div(cents + 50, 100) * 100

  @doc "Formats integer cents as a display string, e.g. `4000 → \"$40\"`, `4999 → \"$49.99\"`."
  @spec format_cents(integer()) :: String.t()
  def format_cents(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    cts = rem(cents, 100)
    if cts == 0, do: "$#{dollars}", else: "$#{dollars}.#{String.pad_leading("#{cts}", 2, "0")}"
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # cents × (bps / 10_000), truncated — round_psych does the single final rounding.
  defp ratio(cents, bps), do: div(cents * bps, @basis)

  defp band_bps(key) when is_atom(key) do
    %{bps: bps} = Enum.find(@bands, &(&1.key == key))
    bps
  end
end
