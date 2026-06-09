# Regional Pricing — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship cost-of-living-adjusted (4-band) + annual + volume pricing — displayed as struck-through prices on the home page and `billing_live`, charged through an idempotent resolver against the payment stub, with a verbose anti-arbitrage audit log — without yet moving real money.

**Architecture:** A pure `Billing.Pricing` core (band math over integer cents, reads numbers from `Billing.Prices`) drives both display (a band-aware function component on two surfaces) and an idempotent `Billing.resolve_charge` (single `Ecto.Multi` + DB-unique idempotency, personal-path-only). Country comes from Cloudflare `CF-IPCountry` (display) via a shared `Compliance` reader; an append-only `PricingAudit` table + a config-selected `RiskSignals` adapter record every discounted decision (flag-don't-block). Annual subscriptions gain an `interval` field and a lump-sum credit grant.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto (binary_id, `Ecto.Enum` string enums), Oban, `Phoenix.LiveView.JS`, daisyUI, ExUnit (DataCase/ConnCase), `:telemetry`.

**Source spec:** `docs/superpowers/specs/2026-06-06-regional-pricing-design.md` (converged 0C/0M).

**Conventions for every task:**
- You are on branch `worktree-european-compliance`. Commit per task; do NOT merge (the orchestrator integrates at the end).
- Run tests with `MIX_TEST_PARTITION=eu` to stay isolated from parallel agents.
- TDD: write the failing test, watch it fail, implement minimally, watch it pass, commit.
- **All money is integer cents.** Multipliers are **basis points** (`bps`) integers; apply as `div(cents * bps, 10_000)`; round once at the end.

---

## GROUP A — Pure pricing core (no DB, no UI)

### Task 1: `Billing.Prices` gains integer `list_cents` + restructured pack catalogue

**Files:**
- Modify: `lib/perfect_paper/billing/prices.ex`
- Test: `test/perfect_paper/billing/prices_list_cents_test.exs`

The current `credit_packs/0` ships `:pack_1/:pack_3/:pack_10` (display-string prices only). Replace with `:pack_3/:pack_6/:pack_12` bundles (the single credit gets its own accessor), and add an integer `list_cents` to every subscription and pack. Subscriptions today are `:starter $40 / :professional $100 / :advanced $300`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/billing/prices_list_cents_test.exs
defmodule PerfectPaper.Billing.PricesListCentsTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Billing.Prices

  test "every subscription carries an integer list_cents (Band A monthly)" do
    for p <- Prices.subscriptions() do
      assert is_integer(p.list_cents) and p.list_cents > 0
    end

    by_key = Map.new(Prices.subscriptions(), &{&1.key, &1.list_cents})
    assert by_key.starter == 4000
    assert by_key.professional == 10_000
    assert by_key.advanced == 30_000
  end

  test "credit_packs are the three bundles 3/6/12 with list_cents" do
    keys = Enum.map(Prices.credit_packs(), & &1.key)
    assert keys == [:pack_3, :pack_6, :pack_12]

    by_key = Map.new(Prices.credit_packs(), &{&1.key, {&1.reviews, &1.list_cents}})
    assert by_key.pack_3 == {3, 14_999}
    assert by_key.pack_6 == {6, 29_999}
    assert by_key.pack_12 == {12, 59_999}
  end

  test "the inline single credit is its own accessor (not in the bundle list)" do
    single = Prices.single_credit()
    assert single.key == :credit_single
    assert single.reviews == 1
    assert single.list_cents == 4999
    refute Enum.any?(Prices.credit_packs(), &(&1.key == :credit_single))
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/prices_list_cents_test.exs`
Expected: FAIL — `list_cents`/`reviews` keys missing, `single_credit/0` undefined, packs are still 1/3/10.

- [ ] **Step 3: Edit `lib/perfect_paper/billing/prices.ex`**

In each map returned by `subscriptions/0`, add an integer `list_cents:` (Band-A monthly cents): `:starter` → `list_cents: 4000`, `:professional` → `list_cents: 10_000`, `:advanced` → `list_cents: 30_000`. (Keep the existing `price_label`/`price_env`/etc keys — display strings are now derived but the legacy keys stay until the view layer is migrated.)

Replace `credit_packs/0` with the three bundles and add `single_credit/0`. **As-built note (Task 1 shipped):** keep the **full rich map keys** (`name/price_label/cadence/tagline/badge/savings/features/popular?/mode/cta/price_env`) on each pack — `demo_live/billing.ex` and the prices test read them — and *add* `reviews` + `list_cents` rather than collapse to a minimal map. `do_pack/3` destructures only `%{list_cents, key}`, so the rich shape is safe. The minimal map below is illustrative of the new numeric fields only:

```elixir
  @doc "The three credit bundles, ascending. Single credit is separate (see single_credit/0)."
  @spec credit_packs() :: [map()]
  def credit_packs do
    [
      %{key: :pack_3, reviews: 3, list_cents: 14_999, mode: :payment,
        price_env: "STRIPE_PRICE_PACK_3", cta: "Buy now", popular?: true},
      %{key: :pack_6, reviews: 6, list_cents: 29_999, mode: :payment,
        price_env: "STRIPE_PRICE_PACK_6", cta: "Buy now", popular?: false},
      %{key: :pack_12, reviews: 12, list_cents: 59_999, mode: :payment,
        price_env: "STRIPE_PRICE_PACK_12", cta: "Buy now", popular?: false}
    ]
  end

  @doc "The inline single review credit (a global top-up, not a bundle card)."
  @spec single_credit() :: map()
  def single_credit do
    %{key: :credit_single, reviews: 1, list_cents: 4999, mode: :payment,
      price_env: "STRIPE_PRICE_CREDIT_SINGLE", cta: "Buy one review"}
  end
```

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/prices_list_cents_test.exs`
Expected: PASS.

- [ ] **Step 5: Confirm no caller broke on the pack-key rename**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing test/perfect_paper_web/live/billing_live_test.exs test/perfect_paper_web/live/demo_live`
Expected: PASS. If a test references `:pack_1`/`:pack_10` literally, update it to the new keys (the catalogue genuinely changed — approved prices). `demo_live/billing.ex` iterates generically, so it should be fine.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper/billing/prices.ex test/perfect_paper/billing/prices_list_cents_test.exs
git commit -m "feat(billing): Prices integer list_cents + restructured pack catalogue (3/6/12 + single)"
```

---

### Task 2: `Billing.Pricing` — bands, country→band, resolve_band, round_psych, format_cents

**Files:**
- Create: `lib/perfect_paper/billing/pricing.ex`
- Test: `test/perfect_paper/billing/pricing_bands_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/billing/pricing_bands_test.exs
defmodule PerfectPaper.Billing.PricingBandsTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Billing.Pricing

  test "four bands with basis-point multipliers" do
    assert Map.new(Pricing.bands(), &{&1.key, &1.bps}) ==
             %{a: 10_000, b: 7_500, c: 5_000, d: 3_500}
  end

  test "country_band maps ISO codes; unknown -> :a (least discount, safe)" do
    assert Pricing.country_band("US") == :a
    assert Pricing.country_band("DE") == :a
    assert Pricing.country_band("MX") == :b
    assert Pricing.country_band("RU") == :b
    assert Pricing.country_band("IN") == :c
    assert Pricing.country_band("ET") == :d
    assert Pricing.country_band("ZZ") == :a
    assert Pricing.country_band(nil) == :a
  end

  test "resolve_band picks the LESS generous (larger bps) of two countries" do
    assert Pricing.resolve_band("IN", "US") == :a
    assert Pricing.resolve_band("US", "IN") == :a
    assert Pricing.resolve_band("IN", "IN") == :c
    assert Pricing.resolve_band("MX", nil) == :a
  end

  test "round_psych is idempotent and rounds to whole dollars" do
    assert Pricing.round_psych(1999) == 1999
    assert Pricing.round_psych(2001) == 2000
    assert Pricing.round_psych(Pricing.round_psych(2034)) == Pricing.round_psych(2034)
  end

  test "format_cents renders USD" do
    assert Pricing.format_cents(4000) == "$40"
    assert Pricing.format_cents(1999) == "$19.99"
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/pricing_bands_test.exs`
Expected: FAIL — `PerfectPaper.Billing.Pricing` undefined.

- [ ] **Step 3: Create `lib/perfect_paper/billing/pricing.ex`**

```elixir
defmodule PerfectPaper.Billing.Pricing do
  @moduledoc """
  Pure pricing math: income bands, country→band, the less-generous two-country
  rule, and the subscription/pack/single price calculators over **integer cents**.
  Reads base numbers from `Billing.Prices`; holds no prices of its own.
  Multipliers are basis points (bps); apply once, round once.
  """
  alias PerfectPaper.Billing.Prices

  @bands [
    %{key: :a, bps: 10_000, label: "A"},
    %{key: :b, bps: 7_500, label: "B"},
    %{key: :c, bps: 5_000, label: "C"},
    %{key: :d, bps: 3_500, label: "D"}
  ]
  @bps Map.new(@bands, &{&1.key, &1.bps})

  # Country → band (World Bank income groups; unknown → :a). Only the discounted
  # bands need listing — everything unlisted is Band A (full price, safe default).
  @band_b ~w(MX BR TR RU CN AR CO MY TH ZA RS)
  @band_c ~w(IN ID PH VN EG UA MA NG)
  @band_d ~w(ET CD UG AF)
  @country_band Map.merge(
                  Map.new(@band_b, &{&1, :b}),
                  Map.merge(Map.new(@band_c, &{&1, :c}), Map.new(@band_d, &{&1, :d}))
                )

  @floor_monthly 500
  @floor_annual 5_000
  @floor_pack 999
  @annual_months_charged 10

  @spec bands() :: [map()]
  def bands, do: @bands

  @spec country_band(String.t() | nil) :: :a | :b | :c | :d
  def country_band(code) when is_binary(code), do: Map.get(@country_band, String.upcase(code), :a)
  def country_band(_), do: :a

  @doc "The less-generous (higher-bps) band of the two countries — the binding charge band."
  @spec resolve_band(String.t() | nil, String.t() | nil) :: :a | :b | :c | :d
  def resolve_band(ip_country, payment_country) do
    a = country_band(ip_country)
    b = country_band(payment_country)
    if @bps[a] >= @bps[b], do: a, else: b
  end

  @spec bps(:a | :b | :c | :d) :: pos_integer()
  def bps(band), do: @bps[band]

  @doc "Apply a bps ratio to cents (integer-safe)."
  @spec apply_bps(integer(), integer()) :: integer()
  def apply_bps(cents, bps), do: div(cents * bps, 10_000)

  @doc "Round cents to whole dollars (idempotent)."
  @spec round_psych(integer()) :: integer()
  def round_psych(cents), do: round(cents / 100) * 100

  @spec format_cents(integer()) :: String.t()
  def format_cents(cents) do
    dollars = div(cents, 100)
    case rem(cents, 100) do
      0 -> "$#{dollars}"
      r -> "$#{dollars}.#{String.pad_leading("#{r}", 2, "0")}"
    end
  end

  # exposed for Task 3/4
  @doc false
  def floors, do: %{monthly: @floor_monthly, annual: @floor_annual, pack: @floor_pack}
  @doc false
  def annual_months_charged, do: @annual_months_charged
  @doc false
  def list_cents_for_plan(plan), do: Enum.find(Prices.subscriptions(), &(&1.key == plan)).list_cents
end
```

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/pricing_bands_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/billing/pricing.ex test/perfect_paper/billing/pricing_bands_test.exs
git commit -m "feat(billing): Pricing core — bands, country_band, resolve_band, round_psych, format_cents"
```

---

### Task 3: `Billing.Pricing.price_for/3` — subscription monthly + annual, struck, `price ≤ list`

**Files:**
- Modify: `lib/perfect_paper/billing/pricing.ex`
- Test: `test/perfect_paper/billing/pricing_subscriptions_test.exs`

- [ ] **Step 1: Write the failing test (the worked table)**

```elixir
# test/perfect_paper/billing/pricing_subscriptions_test.exs
defmodule PerfectPaper.Billing.PricingSubscriptionsTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Billing.Pricing

  # Starter list = $40. Worked table from the spec.
  test "starter monthly/annual across all bands" do
    expected = %{
      a: %{monthly: 4000, monthly_struck?: false, annual: 40_000, annual_list: 48_000},
      b: %{monthly: 3000, monthly_struck?: true,  annual: 30_000, annual_list: 36_000},
      c: %{monthly: 2000, monthly_struck?: true,  annual: 20_000, annual_list: 24_000},
      d: %{monthly: 1400, monthly_struck?: true,  annual: 14_000, annual_list: 16_800}
    }

    for {band, e} <- expected do
      m = Pricing.price_for(:starter, band, :monthly)
      assert m.price == e.monthly
      assert m.list == 4000
      assert m.struck? == e.monthly_struck?

      y = Pricing.price_for(:starter, band, :annual)
      assert y.price == e.annual
      assert y.list == e.annual_list
      assert y.struck? == true            # annual always saves 2 months
    end
  end

  test "invariant: price never exceeds list, never below floor" do
    for plan <- [:starter, :professional, :advanced],
        band <- [:a, :b, :c, :d],
        cadence <- [:monthly, :annual] do
      r = Pricing.price_for(plan, band, cadence)
      assert r.price <= r.list
      assert r.price >= 500
    end
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/pricing_subscriptions_test.exs`
Expected: FAIL — `price_for/3` undefined.

- [ ] **Step 3: Add `price_for/3` to `lib/perfect_paper/billing/pricing.ex`**

```elixir
  @doc """
  Price a subscription `plan` for a resolved `band` and `cadence` (`:monthly`|`:annual`).
  Returns integer cents. `struck?` ⇒ show the list struck through.
  """
  @spec price_for(atom(), :a | :b | :c | :d, :monthly | :annual) ::
          %{price: integer(), list: integer(), struck?: boolean(), band: atom(), bps: integer()}
  def price_for(plan, band, :monthly) do
    m = list_cents_for_plan(plan)
    price = clamp(round_psych(apply_bps(m, bps(band))), @floor_monthly, m)
    %{price: price, list: m, struck?: price < m, band: band, bps: bps(band)}
  end

  def price_for(plan, band, :annual) do
    m = list_cents_for_plan(plan)
    list = round_psych(apply_bps(m * 12, bps(band)))
    price = clamp(round_psych(apply_bps(m * @annual_months_charged, bps(band))), @floor_annual, list)
    %{price: price, list: list, struck?: price < list, band: band, bps: bps(band)}
  end

  # never below floor, never above the list it's discounting from
  defp clamp(value, floor, list), do: value |> max(floor) |> min(list)
```

- [ ] **Step 4: Run it, verify it passes**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/pricing_subscriptions_test.exs`
Expected: PASS (all bands + the invariant property).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/billing/pricing.ex test/perfect_paper/billing/pricing_subscriptions_test.exs
git commit -m "feat(billing): Pricing.price_for/3 — banded monthly + annual, struck, price<=list"
```

---

### Task 4: `pack_price_for/2` + `unit_price_for/1` — volume on the 12-pack only

**Files:**
- Modify: `lib/perfect_paper/billing/pricing.ex`
- Test: `test/perfect_paper/billing/pricing_packs_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/billing/pricing_packs_test.exs
defmodule PerfectPaper.Billing.PricingPacksTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Billing.Pricing

  test "only :pack_12 gets the 17% volume discount (Band A)" do
    assert Pricing.pack_price_for(:pack_3, :a).price == 14_999
    assert Pricing.pack_price_for(:pack_3, :a).volume_discount? == false
    assert Pricing.pack_price_for(:pack_6, :a).price == 29_999
    p12 = Pricing.pack_price_for(:pack_12, :a)
    assert p12.volume_discount? == true
    assert p12.list == 59_999
    assert p12.price == round(59_999 * 0.83 / 100) * 100   # round_psych(div(59999*8300,10000))
    assert p12.struck? == true
  end

  test "regional band stacks on packs; price <= list always" do
    for key <- [:pack_3, :pack_6, :pack_12], band <- [:a, :b, :c, :d] do
      r = Pricing.pack_price_for(key, band)
      assert r.price <= r.list
      assert r.price >= 999
    end
  end

  test "unit_price_for is the single credit, regional only" do
    assert Pricing.unit_price_for(:a).price == 4999
    assert Pricing.unit_price_for(:c).price <= 4999
  end
end
```

- [ ] **Step 2: Run, verify fail.** `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/pricing_packs_test.exs` → `pack_price_for/2` undefined.

- [ ] **Step 3: Add to `pricing.ex`**

```elixir
  @volume_bps %{pack_12: 8_300}   # 17% off; all others 10_000 (none)

  @doc "Price a credit bundle for a band. Only :pack_12 carries a volume discount."
  @spec pack_price_for(atom(), :a | :b | :c | :d) ::
          %{price: integer(), list: integer(), struck?: boolean(),
            volume_discount?: boolean(), band: atom(), bps: integer()}
  def pack_price_for(key, band) do
    pack = Enum.find(Prices.credit_packs(), &(&1.key == key))
    do_pack(pack, band, Map.get(@volume_bps, key, 10_000))
  end

  @doc "Price the inline single credit for a band (regional only, no volume)."
  @spec unit_price_for(:a | :b | :c | :d) :: map()
  def unit_price_for(band), do: do_pack(Prices.single_credit(), band, 10_000)

  defp do_pack(%{list_cents: l} = pack, band, vbps) do
    price = clamp(round_psych(apply_bps(apply_bps(l, bps(band)), vbps)), @floor_pack, l)
    %{price: price, list: l, struck?: price < l,
      volume_discount?: vbps < 10_000, band: band, bps: bps(band), key: pack.key}
  end
```

- [ ] **Step 4: Run, verify pass.** `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/pricing_packs_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/billing/pricing.ex test/perfect_paper/billing/pricing_packs_test.exs
git commit -m "feat(billing): Pricing pack_price_for/2 + unit_price_for/1 (17% on pack_12 only)"
```

---

## GROUP B — Request country + display

### Task 5: `Compliance.country_from_conn/1` (shared reader) + `eea?/1`

**Files:**
- Modify: `lib/perfect_paper/compliance.ex`, `lib/perfect_paper_web/controllers/cookie_consent_controller.ex` (use the shared reader)
- Test: `test/perfect_paper/compliance_country_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/compliance_country_test.exs
defmodule PerfectPaper.ComplianceCountryTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Compliance

  defp conn_with(country) do
    %Plug.Conn{} |> Plug.Conn.put_req_header("cf-ipcountry", country)
  end

  test "country_from_conn reads CF-IPCountry, treating ''/XX/missing as nil" do
    assert Compliance.country_from_conn(conn_with("DE")) == "DE"
    assert Compliance.country_from_conn(conn_with("XX")) == nil
    assert Compliance.country_from_conn(conn_with("")) == nil
    assert Compliance.country_from_conn(%Plug.Conn{}) == nil
  end

  test "eea? identifies EU/EEA members" do
    assert Compliance.eea?("DE")
    assert Compliance.eea?("RO")
    refute Compliance.eea?("US")
    refute Compliance.eea?(nil)
  end
end
```

- [ ] **Step 2: Run, verify fail.** Functions undefined.

- [ ] **Step 3: Add to `lib/perfect_paper/compliance.ex`**

```elixir
  @doc "The visitor's country from Cloudflare's CF-IPCountry header, or nil ('', 'XX', missing)."
  @spec country_from_conn(Plug.Conn.t()) :: String.t() | nil
  def country_from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "cf-ipcountry") do
      [c | _] when c not in ["", "XX"] -> c
      _ -> nil
    end
  end

  @eea ~w(AT BE BG HR CY CZ DK EE FI FR DE GR HU IE IT LV LT LU MT NL PL PT RO SK SI ES SE IS LI NO)
  @doc "True if the country is in the EU/EEA (for Omnibus struck-price suppression)."
  @spec eea?(String.t() | nil) :: boolean()
  def eea?(code) when is_binary(code), do: String.upcase(code) in @eea
  def eea?(_), do: false
```

Then in `cookie_consent_controller.ex`, replace its inline `["", "XX"]` country parse with `PerfectPaper.Compliance.country_from_conn(conn)` (keep behavior identical).

- [ ] **Step 4: Run, verify pass + no consent regression.**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper/compliance_country_test.exs test/perfect_paper_web/controllers/cookie_consent_controller_test.exs`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/compliance.ex lib/perfect_paper_web/controllers/cookie_consent_controller.ex test/perfect_paper/compliance_country_test.exs
git commit -m "feat(compliance): shared country_from_conn/1 reader + eea?/1"
```

---

### Task 6: `FetchPricingCountry` plug — assign band + write to session

**Files:**
- Create: `lib/perfect_paper_web/plugs/fetch_pricing_country.ex`
- Modify: `lib/perfect_paper_web/router.ex` (`:browser` pipeline, after `FetchLocale`)
- Test: `test/perfect_paper_web/plugs/fetch_pricing_country_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/plugs/fetch_pricing_country_test.exs
defmodule PerfectPaperWeb.Plugs.FetchPricingCountryTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "assigns band + country and stashes band in session", %{conn: conn} do
    conn = conn |> put_req_header("cf-ipcountry", "MX") |> get(~p"/")
    assert conn.assigns.pricing_band == :b
    assert conn.assigns.pricing_country == "MX"
    assert get_session(conn, :pricing_band) == "b"
  end

  test "missing/XX country -> band :a", %{conn: conn} do
    conn = conn |> put_req_header("cf-ipcountry", "XX") |> get(~p"/")
    assert conn.assigns.pricing_band == :a
  end
end
```

- [ ] **Step 2: Run, verify fail.** `assigns.pricing_band` is nil.

- [ ] **Step 3: Create the plug**

```elixir
# lib/perfect_paper_web/plugs/fetch_pricing_country.ex
defmodule PerfectPaperWeb.Plugs.FetchPricingCountry do
  @moduledoc """
  Resolves the visitor's pricing band from `CF-IPCountry` (via `Compliance`),
  assigns `:pricing_country`/`:pricing_band`, and writes the band into the
  session so the connected LiveView mount (which has no conn assigns) can read it.
  """
  import Plug.Conn
  alias PerfectPaper.{Compliance, Billing.Pricing}

  @behaviour Plug
  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    country = Compliance.country_from_conn(conn)
    band = Pricing.country_band(country)

    conn
    |> assign(:pricing_country, country)
    |> assign(:pricing_band, band)
    |> put_session(:pricing_band, Atom.to_string(band))
  end
end
```

In `router.ex` `:browser` pipeline, add after `plug PerfectPaperWeb.Plugs.FetchLocale`:
```elixir
    plug PerfectPaperWeb.Plugs.FetchPricingCountry
```

- [ ] **Step 4: Run, verify pass.** `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/plugs/fetch_pricing_country_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/plugs/fetch_pricing_country.ex lib/perfect_paper_web/router.ex test/perfect_paper_web/plugs/fetch_pricing_country_test.exs
git commit -m "feat(web): FetchPricingCountry plug (band assign + session)"
```

---

### Task 7: Banded pricing card function component + `Phoenix.LiveView.JS` cadence toggle

**Files:**
- Create: `lib/perfect_paper_web/components/pricing_card.ex`
- Test: `test/perfect_paper_web/components/pricing_card_test.exs`

A single pure function component used by both home and billing. Renders both cadence variants (server-side); the JS toggle reveals one. EU visitors get the regional strike suppressed.

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper_web/components/pricing_card_test.exs
defmodule PerfectPaperWeb.PricingCardTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias PerfectPaperWeb.PricingCard

  defp render_card(assigns), do: rendered_to_string(PricingCard.plan_card(assigns))

  test "Band A monthly shows the price, no strike" do
    html = render_card(%{plan: :starter, band: :a, eea?: false, name: "Starter"})
    assert html =~ "$40"
    refute html =~ "line-through"   # no struck monthly at Band A
  end

  test "Band C monthly is struck $40 -> $20" do
    html = render_card(%{plan: :starter, band: :c, eea?: false, name: "Starter"})
    assert html =~ "$40" and html =~ "$20" and html =~ "line-through"
  end

  test "EU visitor: regional strike suppressed, annual strike kept" do
    html = render_card(%{plan: :starter, band: :c, eea?: true, name: "Starter"})
    # monthly shows only the discounted price (no struck $40)
    refute html =~ ~s(line-through">$40)
    # annual still struck (genuine saving)
    assert html =~ "data-cadence=\"annual\""
  end

  test "renders both cadence variants + the JS toggle hooks" do
    html = render_card(%{plan: :starter, band: :a, eea?: false, name: "Starter"})
    assert html =~ "data-cadence=\"monthly\""
    assert html =~ "data-cadence=\"annual\""
    assert html =~ "phx-click" or html =~ "data-cadence-toggle"
  end
end
```

- [ ] **Step 2: Run, verify fail.** Module undefined.

- [ ] **Step 3: Create `lib/perfect_paper_web/components/pricing_card.ex`**

```elixir
defmodule PerfectPaperWeb.PricingCard do
  @moduledoc "Band-aware subscription pricing card (pure function component, JS cadence toggle)."
  use PerfectPaperWeb, :html
  alias PerfectPaper.Billing.Pricing

  attr :plan, :atom, required: true
  attr :band, :atom, required: true
  attr :eea?, :boolean, default: false
  attr :name, :string, required: true

  def plan_card(assigns) do
    assigns =
      assigns
      |> assign(:m, Pricing.price_for(assigns.plan, assigns.band, :monthly))
      |> assign(:y, Pricing.price_for(assigns.plan, assigns.band, :annual))

    ~H"""
    <div class="pricing-card rounded-box border border-base-300 p-6" data-plan={@plan}>
      <h3 class="font-display text-xl font-semibold">{@name}</h3>

      <div data-cadence="monthly">
        <span :if={@m.struck? and not @eea?} class="font-sans text-base-content/45 line-through">
          {Pricing.format_cents(@m.list)}
        </span>
        <span class="font-display text-2xl font-semibold">{Pricing.format_cents(@m.price)}</span>
        <span class="text-sm text-base-content/55">/mo</span>
      </div>

      <div data-cadence="annual" class="hidden">
        <span :if={@y.struck?} class="font-sans text-base-content/45 line-through">
          {Pricing.format_cents(@y.list)}
        </span>
        <span class="font-display text-2xl font-semibold">{Pricing.format_cents(@y.price)}</span>
        <span class="text-sm text-base-content/55">/yr</span>
      </div>
    </div>
    """
  end

  @doc "Monthly/annual toggle button group, client-side via Phoenix.LiveView.JS."
  def cadence_toggle(assigns) do
    ~H"""
    <div class="join" role="group" aria-label={gettext("Billing period")}>
      <button type="button" class="btn btn-sm join-item" data-cadence-toggle="monthly"
        phx-click={JS.add_class("hidden", to: "[data-cadence=annual]") |> JS.remove_class("hidden", to: "[data-cadence=monthly]")}>
        {gettext("Monthly")}
      </button>
      <button type="button" class="btn btn-sm join-item" data-cadence-toggle="annual"
        phx-click={JS.add_class("hidden", to: "[data-cadence=monthly]") |> JS.remove_class("hidden", to: "[data-cadence=annual]")}>
        {gettext("Annual")}
      </button>
    </div>
    """
  end
end
```

- [ ] **Step 4: Run, verify pass.** `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/components/pricing_card_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/components/pricing_card.ex test/perfect_paper_web/components/pricing_card_test.exs
git commit -m "feat(web): band-aware pricing card component + JS cadence toggle"
```

---

### Task 8: Wire banded cards into the home `#pricing` section

**Files:**
- Modify: `lib/perfect_paper_web/controllers/page_controller.ex` (assign band/eea), `lib/perfect_paper_web/controllers/page_html/home.html.heex` (`#pricing` section), `lib/perfect_paper_web/controllers/page_html.ex` (import the component if needed)
- Test: `test/perfect_paper_web/controllers/page_controller_test.exs` (extend)

- [ ] **Step 1: Write the failing test (extend the existing file)**

```elixir
  test "home #pricing shows banded prices for a Mexico (Band B) visitor", %{conn: conn} do
    body = conn |> put_req_header("cf-ipcountry", "MX") |> get(~p"/") |> html_response(200)
    # Band B starter monthly = $30 struck from $40
    assert body =~ "$30" and body =~ "line-through"
    assert body =~ ~s(data-cadence="annual")
  end

  test "home #pricing full price + no strike for a US (Band A) visitor", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "$40"
  end
```

- [ ] **Step 2: Run, verify fail.** Band B body won't contain `$30`/struck markup yet.

- [ ] **Step 3: Implement**

In `page_controller.ex`, `home/2` must pass the band + eea flag:
```elixir
  def home(conn, _params) do
    render(conn, :home,
      pricing_band: conn.assigns.pricing_band,
      pricing_eea?: PerfectPaper.Compliance.eea?(conn.assigns.pricing_country)
    )
  end
```

In `home.html.heex`, replace the inline `#pricing` plan loop (the `:for={product <- Prices.list()}` block) with the component (one card per plan), passing `@pricing_band`/`@pricing_eea?`, and add the `<PricingCard.cadence_toggle />` above the grid. In `page_html.ex` add `import PerfectPaperWeb.PricingCard` (or call fully-qualified). Remove the now-dead `plan_price/1`/`plan_name/1` string formatting for the subscription cards (keep anything still used elsewhere; grep first).

- [ ] **Step 4: Run, verify pass + no other page regressions.**

Run: `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: PASS. Fix any existing home-pricing assertion that referenced the old raw `$40` markup to match the new component output.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/controllers/page_controller.ex lib/perfect_paper_web/controllers/page_html/home.html.heex lib/perfect_paper_web/controllers/page_html.ex test/perfect_paper_web/controllers/page_controller_test.exs
git commit -m "feat(web): banded pricing cards on home #pricing"
```

---

### Task 9: Band into `billing_live` (connected mount) + banded subscription cards

**Files:**
- Modify: `lib/perfect_paper_web/live/billing_live.ex`
- Test: `test/perfect_paper_web/live/billing_live_test.exs` (extend)

- [ ] **Step 1: Write the failing test**

```elixir
  test "billing page shows banded subscription prices for a Band C user", %{conn: conn} do
    user = user_fixture()
    conn = conn |> log_in_user(user) |> put_req_header("cf-ipcountry", "IN")
    {:ok, _lv, html} = live(conn, ~p"/billing")
    assert html =~ "$20"            # starter monthly Band C
    assert html =~ ~s(data-cadence="annual")
  end
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement**

In `billing_live.ex`, bind the **`session` argument of `mount/3`** (the codebase's real mechanism — `get_connect_info(socket, :session)` is NOT a valid call; `FetchLocale`→`:load_locale` reads the session arg the same way). `mount/3` is currently `def mount(_params, _session, socket)` — it discards the session; bind and read it:

```elixir
  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user

    band =
      case session do
        %{"pricing_band" => b} when is_binary(b) -> String.to_existing_atom(b)
        _ -> :a
      end

    {:ok,
     assign(socket,
       page_title: gettext("Subscription & credits"),
       tab: :subscription,
       user: user,
       products: Billing.list_products(),
       subscription: Billing.get_subscription_for_user(user.id),
       balance: Credits.balance(user.id),
       pricing_band: band,
       pricing_eea?: false
     )}
  end
```
**Set EVERY assign the existing `mount/3` did** (`page_title/tab/user/products/subscription/balance`) — do not leave a prose placeholder; a literal paste of a partial block ships a `KeyError` at render (`@products`/`@subscription`/`@balance`/`@tab` are read by the template). `Billing.list_products/0` and `Billing.get_subscription_for_user/1` exist (verified). The existing assign is named **`balance`** (not `credit_balance`) — Task 14 must match. Reading a string from the session + `String.to_existing_atom` (band atoms `:a–:d` are compile-time loaded in `Pricing.@bands`) is cheap + pure — safe on both the disconnected and connected mount. Replace the subscription card rendering (`plan_price(@product)`) with `<PricingCard.plan_card plan={p.key} band={@pricing_band} name={...} eea?={@pricing_eea?} />` and add the cadence toggle. `eea?` defaults false on the authed page (billing is post-login; the home page is the marketing strike surface).

- [ ] **Step 4: Run, verify pass.** `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/live/billing_live_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/live/billing_live.ex test/perfect_paper_web/live/billing_live_test.exs
git commit -m "feat(web): banded subscription cards in billing_live (band via session)"
```

---

## GROUP C — Charge, audit, risk, annual

### Task 10: `Subscription.interval` field + migration + lump-sum annual grant

**Files:**
- Create: `priv/repo/migrations/20260607120000_add_interval_to_subscriptions.exs`
- Modify: `lib/perfect_paper/billing/subscription.ex` (field + cast), `lib/perfect_paper/credits.ex` (`grant_annual_allowance/2` + drip gate)
- Test: `test/perfect_paper/billing/annual_entitlement_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/billing/annual_entitlement_test.exs
defmodule PerfectPaper.Billing.AnnualEntitlementTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Credits, Repo}
  alias PerfectPaper.Billing.Subscription
  import PerfectPaper.AccountsFixtures

  test "annual subscription grants 12x the monthly allowance once (idempotent per term)" do
    user = user_fixture()
    sub = %Subscription{} |> Subscription.create_changeset(%{user_id: user.id, plan: :starter, interval: :year}) |> Repo.insert!()

    assert {:ok, _} = Credits.grant_annual_allowance(sub, ~U[2026-06-01 00:00:00Z])
    bal1 = Credits.balance(user.id)
    # re-trigger same term: no double-grant
    assert {:ok, :already_granted} = Credits.grant_annual_allowance(sub, ~U[2026-06-01 00:00:00Z])
    assert Credits.balance(user.id) == bal1
    assert bal1 == 12 * Credits.limits_for(:starter).monthly_reviews
  end

  test "monthly drip is suppressed for an annual subscription" do
    # grant_monthly_allowance must skip interval: :year (gate documented in spec)
    user = user_fixture()
    sub = %Subscription{} |> Subscription.create_changeset(%{user_id: user.id, plan: :starter, interval: :year}) |> Repo.insert!()
    assert Credits.grant_monthly_allowance(user.id, :starter, interval: :year) == {:ok, :skipped_annual}
  end
end
```

- [ ] **Step 2: Run, verify fail.** `interval` not castable; `grant_annual_allowance/2` undefined.

- [ ] **Step 3: Migration (additive, nullable→default; safe, std 4)**

```elixir
# priv/repo/migrations/20260607120000_add_interval_to_subscriptions.exs
defmodule PerfectPaper.Repo.Migrations.AddIntervalToSubscriptions do
  use Ecto.Migration

  # Metadata-only on PG11+ (constant default, no table rewrite), but ALTER still
  # takes ACCESS EXCLUSIVE — bound the lock so it can't queue unbounded (std 4;
  # the repo sets no lock_timeout/after_begin anywhere, so set it here).
  def up do
    execute "SET lock_timeout = '5s'"
    alter table(:subscriptions) do
      add :interval, :string, null: false, default: "month"
    end
  end

  def down do
    alter table(:subscriptions) do
      remove :interval
    end
  end
end
```

> **Precondition note (latent bug to confirm, not introduce):** the existing `subscriptions` migration created `plan` with `default: "free"`, but `Subscription`'s `Ecto.Enum` values are `[:starter, :professional, :advanced]` — `"free"` is not a member, so any row holding it fails to load. Confirm no `subscriptions` row holds `"free"` before relying on `grant_annual_allowance`/`resolve_charge` loading existing rows; the fresh-row test below won't catch this.

In `subscription.ex`: add `field :interval, Ecto.Enum, values: [:month, :year], default: :month` to the schema + `:interval` in both `create_changeset` and `change_plan_changeset` casts + to `@type`.

In `credits.ex`, add:
```elixir
  @doc "Grants an annual subscription's lump-sum allowance (12x monthly), idempotent per term."
  @spec grant_annual_allowance(Subscription.t(), DateTime.t()) ::
          {:ok, term()} | {:ok, :already_granted} | {:error, term()}
  def grant_annual_allowance(%{user_id: uid, plan: plan} = _sub, term_start) do
    amount = 12 * Tier.for_plan(plan).monthly_reviews
    key = "annual_allowance:#{uid}:#{DateTime.to_date(term_start)}"
    grant_once(uid, amount, key, :paid)   # illustrative — see note
  end
```
> `grant_once/4` is **illustrative, not an existing function**. `grant_monthly_allowance` dedups via the private `locked_insert/3` + `allowance_granted?/2` (a per-key check inside the user advisory lock). Read those and mirror the pattern — return `{:ok, :already_granted}` when the dedup key is already present (the test asserts this on the second call). Do not call an undefined `grant_once`. (`Tier` is already aliased in `credits.ex`, so `Tier.for_plan/1` resolves.)

Add the drip gate to `grant_monthly_allowance/3`: accept `opts`, and `if Keyword.get(opts, :interval) == :year, do: {:ok, :skipped_annual}` at the top.

- [ ] **Step 4: Migrate + run.**

```bash
MIX_TEST_PARTITION=eu mix ecto.migrate
MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/annual_entitlement_test.exs test/perfect_paper/credits_test.exs
```
Expected: PASS (and no monthly-allowance regression).

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations lib/perfect_paper/billing/subscription.ex lib/perfect_paper/credits.ex test/perfect_paper/billing/annual_entitlement_test.exs
git commit -m "feat(billing): Subscription.interval + annual lump-sum grant + monthly-drip suppression"
```

> **Wire drip-suppression at the CONSUMER, not per-emit-site (closes BOTH `upgrade_plan` and `downgrade_plan`):** there are **two** `subscription.updated` emitters in `billing.ex` — `upgrade_plan/2` AND `downgrade_plan/2` — and `AllowanceServer` calls `grant_monthly_allowance_for_event/1` for *every* one. Gating only on `data.interval` at the upgrade site misses a plan change via `downgrade_plan` (the row stays `interval: :year`, the event omits `interval`, so the gate reads false and the monthly drip fires on an annual sub — the exact double-grant the spec made a deliverable to prevent). So:
> - Add `interval` to the `subscription.updated` event `data` in **both** emit sites (for observability) — source it from the **persisted struct** (`updated.interval`/`subscription.interval`), NOT inbound attrs, since `downgrade_plan` never receives `interval` in params. AND
> - In `Credits.grant_monthly_allowance_for_event/1`, **load the subscription via the `Billing` API** (`Billing.get_subscription_for_user/1` — cross-context through the public API, not `Repo`, per CLAUDE.md law 1; the event's `actor_id` carries the user id) and skip (`{:ok, :skipped_annual}`) when its **persisted `interval == :year`**; fall back to `data.interval` only if no subscription is found. This closes both paths and any future emitter in one place. Add a one-line `@doc`/comment noting this is a deliberate cross-context read so a future reader doesn't "fix" it into a `Repo` call.
> - Tests: (a) an annual `subscription.updated` from `upgrade_plan` grants nothing via the drip handler; **(b) an annual `subscription.updated` from `downgrade_plan` (plan change, `interval` stays `:year`) also grants nothing** — this second case is the one the per-emit-site approach misses.

---

### Task 11: `PricingAudit` schema + table + concurrent index + context

**Files:**
- Create: `lib/perfect_paper/billing/pricing_audit.ex`, `priv/repo/migrations/20260607120100_create_pricing_audits.exs`, `priv/repo/migrations/20260607120200_index_pricing_audits.exs`
- Modify: `lib/perfect_paper/billing.ex` (`record_pricing_decision/1`, `list_pricing_decisions/1`, `anonymize_pricing_audit/1`)
- Test: `test/perfect_paper/billing/pricing_audit_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/billing/pricing_audit_test.exs
defmodule PerfectPaper.Billing.PricingAuditTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Billing
  import PerfectPaper.AccountsFixtures

  test "record + list pricing decisions" do
    u = user_fixture()
    assert {:ok, row} = Billing.record_pricing_decision(%{
      user_id: u.id, ip_country: "IN", payment_country: nil, locale: "hi",
      product: "starter", cadence: "monthly", applied_band: "c",
      applied_multiplier: 5000, list_cents: 4000, applied_cents: 2000,
      mismatches: [], account_country_history: ["IN"]
    })
    assert row.applied_band == "c"
    assert [^row] = Billing.list_pricing_decisions(user_id: u.id)
  end

  test "anonymize_pricing_audit nulls user_id + history (erasure hook)" do
    u = user_fixture()
    {:ok, _} = Billing.record_pricing_decision(%{user_id: u.id, ip_country: "IN", product: "starter",
      cadence: "monthly", applied_band: "c", applied_multiplier: 5000, list_cents: 4000,
      applied_cents: 2000, account_country_history: ["IN"]})
    assert {1, _} = Billing.anonymize_pricing_audit(u.id)
    [row] = Billing.list_pricing_decisions(limit: 100) |> Enum.filter(&(&1.ip_country == "IN"))
    assert is_nil(row.user_id) and row.account_country_history == []
  end
end
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Schema + migrations + context**

`pricing_audit.ex` — `binary_id` PK, fields: `user_id :binary_id` (nullable), `ip_country/payment_country/locale/applied_band/product/cadence :string`, `list_cents/applied_cents/applied_multiplier/risk_score :integer`, `vpn?/datacenter? :boolean`, `account_country_history {:array, :string} default: []`, `mismatches {:array, :string} default: []`, `timestamps(updated_at: false)`. `changeset/2` casts all fields; **`validate_required` ONLY** `[:ip_country, :product, :cadence, :applied_band, :applied_multiplier, :list_cents, :applied_cents]`. Everything else is optional: `user_id` (nullable for anonymized rows), `payment_country`/`locale` (may be absent), `risk_score`/`vpn?`/`datacenter?` (set-once, may be enriched later), and the arrays (`account_country_history`/`mismatches` default `[]`). Do **not** require `payment_country`/`locale`/`mismatches` — the audit tests omit them.

Table migration: `create table(:pricing_audits, primary_key: false)` with `add :id, :binary_id, primary_key: true`, the columns above (arrays `default: []`), `add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)`, `timestamps(updated_at: false)`.

Index migration (separate; concurrent):
```elixir
defmodule PerfectPaper.Repo.Migrations.IndexPricingAudits do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "SET lock_timeout = '5s'"   # @disable_ddl_transaction ⇒ no SET LOCAL; session-level
    create index(:pricing_audits, [:inserted_at], concurrently: true)
    create index(:pricing_audits, [:user_id], concurrently: true)
    create index(:pricing_audits, [:risk_score],
             concurrently: true, where: "risk_score > 0", name: :pricing_audits_flagged_idx)
  end

  def down do
    drop index(:pricing_audits, [:inserted_at], concurrently: true)
    drop index(:pricing_audits, [:user_id], concurrently: true)
    drop index(:pricing_audits, [], name: :pricing_audits_flagged_idx, concurrently: true)
  end
end
```

`Billing` context: `record_pricing_decision/1` (changeset → `Repo.insert`), `list_pricing_decisions/1` (filters by `:user_id`/`:flagged`/`:limit`; **admin-gated at the web layer — document in the @doc**), `anonymize_pricing_audit/1` (`from p in PricingAudit, where: p.user_id == ^id` → `Repo.update_all(set: [user_id: nil, account_country_history: []])`).

- [ ] **Step 4: Migrate + run.**

```bash
MIX_TEST_PARTITION=eu mix ecto.migrate
MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/pricing_audit_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/billing/pricing_audit.ex priv/repo/migrations lib/perfect_paper/billing.ex test/perfect_paper/billing/pricing_audit_test.exs
git commit -m "feat(billing): PricingAudit append-only table + context (record/list/anonymize)"
```

---

### Task 12: `RiskSignals` behaviour + stub adapter (timeout/breaker) + config

**Files:**
- Create: `lib/perfect_paper/billing/risk_signals.ex`, `lib/perfect_paper/billing/risk_signals/stub.ex`
- Modify: `config/config.exs` (`:pricing_risk_provider`)
- Test: `test/perfect_paper/billing/risk_signals_stub_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/billing/risk_signals_stub_test.exs
defmodule PerfectPaper.Billing.RiskSignalsStubTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Billing.RiskSignals.Stub

  test "stub returns a well-shaped, non-vendor map" do
    assert {:ok, %{vpn?: false, datacenter?: false, asn: nil, source: :stub}} = Stub.check("203.0.113.1", [])
  end
end
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Behaviour + stub (mirror the `Chatbot.LLM` pattern)**

```elixir
# lib/perfect_paper/billing/risk_signals.ex
defmodule PerfectPaper.Billing.RiskSignals do
  @moduledoc "Port for IP risk signals (VPN/datacenter). Config-selected adapter; flag-don't-block."
  @callback check(ip :: String.t(), opts :: keyword()) ::
              {:ok, %{vpn?: boolean(), datacenter?: boolean(), asn: integer() | nil, source: atom()}}
              | {:error, term()}
end

# lib/perfect_paper/billing/risk_signals/stub.ex
defmodule PerfectPaper.Billing.RiskSignals.Stub do
  @behaviour PerfectPaper.Billing.RiskSignals
  @impl true
  def check(_ip, _opts), do: {:ok, %{vpn?: false, datacenter?: false, asn: nil, source: :stub}}
end
```

In `config/config.exs`: `config :perfect_paper, :pricing_risk_provider, PerfectPaper.Billing.RiskSignals.Stub`.

**Supervision (required for `run_risk`'s `async_nolink` in Task 13):** add a supervised task supervisor to `lib/perfect_paper/application.ex` children — `{Task.Supervisor, name: PerfectPaper.TaskSupervisor}` (place it before the endpoint). It's a `:supervisor` child under the app's existing `:one_for_one` strategy; no other tree change. Without it, `Task.Supervisor.async_nolink(PerfectPaper.TaskSupervisor, …)` raises `:noproc`.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/billing/risk_signals.ex lib/perfect_paper/billing/risk_signals/stub.ex config/config.exs test/perfect_paper/billing/risk_signals_stub_test.exs
git commit -m "feat(billing): RiskSignals behaviour + stub adapter (config-selected)"
```

---

### Task 13: `Billing.resolve_charge/7` — band resolution, single `Ecto.Multi`, idempotency, audit, telemetry

**Files:**
- Modify: `lib/perfect_paper/billing.ex`
- Create: `priv/repo/migrations/20260607120300_create_pricing_orders.exs` (the idempotency-keyed order row)
- Test: `test/perfect_paper/billing/resolve_charge_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/billing/resolve_charge_test.exs
defmodule PerfectPaper.Billing.ResolveChargeTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Billing, Credits}
  import PerfectPaper.AccountsFixtures

  defmodule OkRisk do
    @behaviour PerfectPaper.Billing.RiskSignals
    def check(_ip, _o), do: {:ok, %{vpn?: true, datacenter?: false, asn: 64500, source: :test}}
  end

  test "binding band is the less-generous of IP vs payment; grants + audits in one txn" do
    u = user_fixture()
    key = "test-#{System.unique_integer([:positive])}"
    assert {:ok, res} = Billing.resolve_charge(u, :pack_12, :one_time, "IN", "US", key, risk_signals: OkRisk)
    # payment US (band A) is less generous than IP IN (band C) -> NO regional discount.
    # pack_12 still carries its unconditional 17% volume discount (Task 4): $599.99 -> $499.
    assert res.band == :a
    assert res.applied_cents == 49_800
    assert Credits.balance(u.id) == 12
    assert [audit] = Billing.list_pricing_decisions(user_id: u.id)
    assert audit.applied_band == "a" and audit.vpn? == true
  end

  test "idempotency key prevents a double grant on retry" do
    u = user_fixture()
    key = "dup-#{System.unique_integer([:positive])}"
    {:ok, _} = Billing.resolve_charge(u, :pack_3, :one_time, "IN", "IN", key, risk_signals: OkRisk)
    bal = Credits.balance(u.id)
    {:ok, _} = Billing.resolve_charge(u, :pack_3, :one_time, "IN", "IN", key, risk_signals: OkRisk)
    assert Credits.balance(u.id) == bal      # no double grant
  end

  test "org/group purchase is refused (personal-path only)" do
    u = user_fixture()
    assert {:error, :org_purchase_unsupported} =
             Billing.resolve_charge(u, :pack_3, :one_time, "US", "US", "k1", owner_type: :group)
  end
end
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement**

Order table migration (idempotency key + DB unique):
```elixir
defmodule PerfectPaper.Repo.Migrations.CreatePricingOrders do
  use Ecto.Migration
  def change do
    create table(:pricing_orders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :idempotency_key, :string, null: false
      add :product, :string, null: false
      add :cadence, :string, null: false
      add :applied_band, :string, null: false
      add :applied_cents, :integer, null: false
      timestamps(type: :utc_datetime)
    end
    create unique_index(:pricing_orders, [:idempotency_key])
  end
end
```

`Billing.resolve_charge/7`:
```elixir
  def resolve_charge(user, product, cadence, ip_country, payment_country, idem_key, opts \\ []) do
    if Keyword.get(opts, :owner_type) == :group do
      {:error, :org_purchase_unsupported}
    else
      band = Pricing.resolve_band(ip_country, payment_country)
      priced = price_product(product, band, cadence)        # uses Pricing.* (pack/unit/plan)
      risk = run_risk(ip_country, opts)                      # tight-timeout/breaker; risk_unknown on error
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Ecto.Multi.new()
      # Same advisory lock key Credits uses, taken in OUR Multi (do NOT call
      # Credits' private lock_user/2 — CLAUDE.md law 1). Serializes the
      # account_country_history read-then-append for the same user.
      |> Ecto.Multi.run(:lock, fn repo, _ ->
        repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [user.id])
        {:ok, :locked}
      end)
      |> Ecto.Multi.insert(:order, order_changeset(user, product, cadence, band, priced.price, idem_key))
      |> Ecto.Multi.run(:grant, fn _repo, _ -> grant_for_product(user, product, cadence) end)
      |> Ecto.Multi.run(:audit, fn _repo, _ ->
        PerfectPaper.Billing.record_pricing_decision(audit_attrs(user, product, cadence, band, priced, ip_country, payment_country, risk))
      end)
      |> PerfectPaper.Repo.transaction()
      |> case do
        {:ok, %{order: order}} ->
          :telemetry.execute([:perfect_paper, :billing, :pricing_decision],
            %{list_cents: priced.list, applied_cents: priced.price},
            %{applied_band: band, product: product, cadence: cadence,
              risk_score: risk_score(risk),
              mismatch?: priced.band != Pricing.country_band(ip_country)})
          {:ok, %{band: band, applied_cents: priced.price, order_id: order.id}}

        {:error, :order, %Ecto.Changeset{} = cs, _} ->
          if unique_violation?(cs, :idempotency_key) do
            {:ok, replay_existing(idem_key)}     # retry → return original, no double grant
          else
            {:error, cs}
          end

        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end
```
Implement the private helpers:
- `price_product` dispatches plan→`Pricing.price_for/3`, `:pack_*`→`pack_price_for/2`, `:credit_single`→`unit_price_for/1`.
- `grant_for_product` grants `reviews` credits via `Credits.grant`.
- `audit_attrs` builds the `record_pricing_decision/1` map (incl. `risk` flags when present).
- `unique_violation?(cs, :idempotency_key)` checks the changeset error; `replay_existing(idem_key)` re-reads the existing `pricing_orders` row. (Watch-item: under a genuine concurrent double-submit the original row may not yet be visible on the constraint-violation path — acceptable on the stub; harden to `ON CONFLICT DO NOTHING` + re-select in Phase 2.)
- **`run_risk` — REQUIRED `:telemetry.span/3` (the spec's second telemetry event) + a 300ms timeout. The stateful circuit breaker is DESCOPED to Phase 2** (a breaker needs supervised ETS/`:persistent_term` state with no home in Phase 1; the tight timeout already bounds blast radius, and the spec permits the deferred path):

```elixir
  defp run_risk(ip_country, opts) do
    adapter = opts[:risk_signals] || Application.get_env(:perfect_paper, :pricing_risk_provider)

    :telemetry.span([:perfect_paper, :billing, :risk_signals], %{}, fn ->
      # async_nolink so an adapter that *raises* (not just returns {:error,_}) can't
      # propagate a linked EXIT and take down the checkout process — Task.yield only
      # catches the yield path, not a linked crash. This is what makes flag-don't-block
      # actually hold for the first real adapter (the stub never raises).
      task =
        Task.Supervisor.async_nolink(PerfectPaper.TaskSupervisor, fn ->
          adapter.check(ip_country, opts)
        end)

      result =
        case Task.yield(task, 300) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, signals}} -> {:ok, signals}
          _ -> {:ok, :risk_unknown}
        end

      {result, %{result: elem(result, 0)}}
    end)
  end

  defp risk_score({:ok, %{} = s}), do: Map.get(s, :risk_score, 0)
  defp risk_score(_), do: 0
```

(Add a test asserting the `[:perfect_paper, :billing, :risk_signals]` span fires — attach a handler with a **per-test unique id** (e.g. `"risk-span-#{System.unique_integer()}"`), have it `send(self(), …)`, `on_exit` **detach** it, and assert the `:stop` event. A fixed handler id under `async: true` collides across the partition — telemetry handler ids are process-global.)

**Register both events in `PerfectPaperWeb.Telemetry.metrics/0`** (spec §Telemetry — they're "required deliverables," not just emitted): add alongside the existing metrics —
```elixir
      summary("perfect_paper.billing.pricing_decision.applied_cents", tags: [:applied_band, :cadence]),
      counter("perfect_paper.billing.pricing_decision.count", tags: [:applied_band, :mismatch?]),
      summary("perfect_paper.billing.risk_signals.stop.duration", unit: {:native, :millisecond}, tags: [:result])
```
Without this the events fire but feed no dashboard, leaving the deliverable unwired.

- [ ] **Step 4: Migrate + run.**

```bash
MIX_TEST_PARTITION=eu mix ecto.migrate
MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/resolve_charge_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/billing.ex priv/repo/migrations test/perfect_paper/billing/resolve_charge_test.exs
git commit -m "feat(billing): resolve_charge — band + idempotent single-Multi grant/order/audit + telemetry"
```

---

### Task 14: Wire `resolve_charge` into `billing_live` purchase events (stub) + enable pack section

**Files:**
- Modify: `lib/perfect_paper_web/live/billing_live.ex`
- Test: `test/perfect_paper_web/live/billing_live_test.exs` (extend)

- [ ] **Step 1: Write the failing test**

```elixir
  test "buying a pack grants credits via resolve_charge (stub)", %{conn: conn} do
    user = user_fixture()
    conn = conn |> log_in_user(user) |> put_req_header("cf-ipcountry", "US")
    {:ok, lv, _} = live(conn, ~p"/billing")
    lv |> element(~s([phx-click="buy_pack"][phx-value-pack="pack_3"])) |> render_click()
    assert PerfectPaper.Credits.balance(user.id) == 3
  end
```

- [ ] **Step 2: Run, verify fail.** (Pack section is currently hardcoded + disabled.)

- [ ] **Step 3: Implement**

Replace the hardcoded `credit_pack_card` cells (the `price_cents={499/1299/3999}` "Coming soon" block) with catalogue-driven, band-aware pack cards (`PricingCard`/a pack variant fed `Pricing.pack_price_for(key, @pricing_band)`), each with `phx-click="buy_pack" phx-value-pack={key}`. Add the handler:
```elixir
  def handle_event("buy_pack", %{"pack" => pack}, socket) do
    user = socket.assigns.current_scope.user
    key = String.to_existing_atom(pack)
    # Idempotent within a short window — a double-click / reconnect lands in the SAME
    # day bucket → unique-index collision → replay the original order (no double grant).
    # A bare "pack:user:key" key + UNIQUE index would let each pack be bought exactly
    # ONCE EVER (every later click replays the first order, granting no credits — a real
    # product defect). A per-day bucket gives a genuine re-buy on a later day a fresh key.
    # NEVER System.system_time per click (that defeats double-click idempotency entirely).
    bucket = Date.utc_today() |> Date.to_iso8601()
    idem = "pack:#{user.id}:#{key}:#{bucket}"
    case Billing.resolve_charge(user, key, :one_time, nil, nil, idem) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Credits added."))
         |> assign(:balance, Credits.balance(user.id))}   # assign name matches mount/template

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not complete the purchase."))}
    end
  end
```
(If sub-day repeat buys must work, pass a per-mount nonce assigned in `mount/3` and reused for the click instead of/alongside the bucket — never `System.system_time`. The UNIQUE index on `idempotency_key` stays.) Also fix the stale "10 credits per review" copy while here (`@proofreading_cost = 1`).

- [ ] **Step 4: Run, verify pass.** `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/live/billing_live_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/live/billing_live.ex test/perfect_paper_web/live/billing_live_test.exs
git commit -m "feat(web): billing_live pack purchase via resolve_charge (catalogue-driven, banded)"
```

---

### Task 15: Retention — `:maintenance` queue + Cron + batched anonymizer Oban job

**Files:**
- Modify: `config/config.exs` (Oban queues + Cron plugin), `lib/perfect_paper/billing.ex` (or a worker module)
- Create: `lib/perfect_paper/billing/pricing_audit_pruner.ex`
- Test: `test/perfect_paper/billing/pricing_audit_pruner_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/perfect_paper/billing/pricing_audit_pruner_test.exs
defmodule PerfectPaper.Billing.PricingAuditPrunerTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{Billing, Repo}
  alias PerfectPaper.Billing.{PricingAudit, PricingAuditPruner}
  import PerfectPaper.AccountsFixtures

  test "anonymizes rows older than 180 days, leaves recent rows" do
    u = user_fixture()
    {:ok, old} = Billing.record_pricing_decision(%{user_id: u.id, ip_country: "IN", product: "p",
      cadence: "monthly", applied_band: "c", applied_multiplier: 5000, list_cents: 4000, applied_cents: 2000})
    # backdate
    Repo.update_all(from(p in PricingAudit, where: p.id == ^old.id), set: [inserted_at: ~U[2025-01-01 00:00:00Z]])
    {:ok, _} = Billing.record_pricing_decision(%{user_id: u.id, ip_country: "US", product: "p",
      cadence: "monthly", applied_band: "a", applied_multiplier: 10000, list_cents: 4000, applied_cents: 4000})

    assert :ok = perform_job(PricingAuditPruner, %{})

    rows = Repo.all(PricingAudit)
    assert Enum.find(rows, &(&1.ip_country == "IN")).user_id == nil
    assert Enum.find(rows, &(&1.ip_country == "US")).user_id == u.id
  end
end
```
(Add `import Oban.Testing, repo: PerfectPaper.Repo` and `import Ecto.Query` to the test.)

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement**

`config/config.exs` Oban → add the queue + Cron plugin:
```elixir
config :perfect_paper, Oban,
  repo: PerfectPaper.Repo,
  queues: [webhooks: 10, documents: 10, reviews: 10, teams_notifier: 5, maintenance: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron, crontab: [{"0 3 * * *", PerfectPaper.Billing.PricingAuditPruner}]}
  ]
```

`pricing_audit_pruner.ex` — `use Oban.Worker, queue: :maintenance`. `perform/1` batches a keyset anonymize loop: repeatedly `UPDATE … SET user_id=NULL, account_country_history='{}' WHERE id IN (SELECT id FROM pricing_audits WHERE inserted_at < $cutoff AND user_id IS NOT NULL ORDER BY id LIMIT 1000)` until 0 rows affected, with `lock_timeout`. Cutoff = `DateTime.add(now, -180, :day)`.

- [ ] **Step 4: Run, verify pass.** `MIX_TEST_PARTITION=eu mix test test/perfect_paper/billing/pricing_audit_pruner_test.exs`

- [ ] **Step 5: Commit**

```bash
git add config/config.exs lib/perfect_paper/billing/pricing_audit_pruner.ex test/perfect_paper/billing/pricing_audit_pruner_test.exs
git commit -m "feat(billing): 180-day PricingAudit anonymizer (Oban Cron, :maintenance queue, batched)"
```

---

### Task 16: Privacy-policy copy + final verification

**Files:**
- Modify: `lib/perfect_paper_web/controllers/page_html/privacy.html.heex`
- Test: `test/perfect_paper_web/controllers/page_controller_test.exs` (extend the privacy test)

- [ ] **Step 1: Add a failing assertion to the existing privacy test**

```elixir
    test "privacy notice covers geo pricing + fraud risk-scoring", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)
      assert body =~ "regional pricing" or body =~ "cost-of-living"
      assert body =~ "fraud" and (body =~ "risk" or body =~ "country")
    end
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3:** Add a short paragraph to `privacy.html.heex` (in the data-collection/cookies area) covering: we use your approximate country (from your IP, via Cloudflare) to show regional pricing, and retain coarse pricing-decision records (country, not full IP) for up to 180 days to prevent pricing fraud; this is a legitimate-interest basis and is never used to make an automated decision against you. Wrap strings in `gettext`.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/controllers/page_html/privacy.html.heex test/perfect_paper_web/controllers/page_controller_test.exs
git commit -m "docs(privacy): disclose geo pricing + fraud risk-scoring (legitimate interest, no Art.22 decision)"
```

---

### Task 17: Pre-merge verification

- [ ] **Step 1: Format + full suite under the partition**

Run: `MIX_TEST_PARTITION=eu mix precommit`
Expected: compiles `--warnings-as-errors`, format clean, **0 failures**. Fix anything red.

- [ ] **Step 2: Integrate main + re-verify**

```bash
git merge --no-edit main && mix deps.get && MIX_TEST_PARTITION=eu mix test
```
Resolve conflicts (billing/credits/billing_live are the likely hot spots), re-run.

- [ ] **Step 3: Fast-forward main** (main not checked out elsewhere) and verify the new modules landed:

```bash
git rev-list main ^worktree-european-compliance   # expect empty
git fetch . worktree-european-compliance:main
git show main:lib/perfect_paper/billing/pricing.ex >/dev/null && echo "landed"
```

- [ ] **Step 4: Report** "committed and merged back to main with no issues."

---

## Self-Review

**Spec coverage:**
- Bands/country/resolve_band/round/format → Task 2 ✓; subscription math → Task 3 ✓; pack/single + 17% → Task 4 ✓; `list_cents`/catalogue restructure → Task 1 ✓.
- Shared `Compliance.country_from_conn` + `eea?` → Task 5 ✓; `FetchPricingCountry` + session → Task 6 ✓; banded card + JS toggle → Task 7 ✓; home surface → Task 8 ✓; billing_live display + band-via-session → Task 9 ✓.
- `Subscription.interval` + annual lump-sum + drip suppression + event payload → Task 10 ✓; `PricingAudit` + concurrent index + anonymize → Task 11 ✓; `RiskSignals` behaviour+stub → Task 12 ✓; idempotent single-`Multi` `resolve_charge` + telemetry + org guard → Task 13 ✓; billing_live purchase wiring + stale copy → Task 14 ✓; 180-day Cron pruner + `:maintenance` queue → Task 15 ✓; privacy copy → Task 16 ✓.
- EU Omnibus strike suppression → Task 7 (`eea?` gate in the card) ✓.

**Gaps deferred to Phase 2 (per spec, not this plan):** payment-country enforcement at a real charge; richer `RiskSignals` adapter; the stateful **circuit breaker** (needs a supervised ETS/`:persistent_term` owner — Phase 1 ships the 300ms timeout + the `:telemetry.span` only); VAT-inclusive display; `replay_existing` hardening to `ON CONFLICT DO NOTHING` + re-select.

**Placeholder scan:** the helper internals in Task 13 (`price_product`/`grant_for_product`/`run_risk`/`replay_existing`) are described, not fully coded — the implementer writes them from the named contracts. Everything else ships complete code. If executing via subagents, the Task 13 agent should be told to implement those privates against the test, which fully pins the behavior.

**Type consistency:** `Pricing.price_for/3` returns `%{price, list, struck?, band, bps}`; `pack_price_for/2`/`unit_price_for/1` add `volume_discount?`/`key`. `resolve_charge/7` arity is consistent across Tasks 13–14. `record_pricing_decision/1` attrs match the schema in Task 11. Band keys are atoms `:a/:b/:c/:d` everywhere; session stores the string form (`"b"`), converted with `String.to_existing_atom`.
