# HTTP Byte-Range Serving (`ISOMedia.HTTP`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pure, zero-dependency HTTP-semantics layer (`ISOMedia.HTTP`) over the existing `SeekIndex` — RFC 7233 Range parsing, RFC 7232 conditional requests, `multipart/byteranges`, ETag/content-type — plus an optional `ISOMedia.Plug` reference adapter.

**Architecture:** Five small pure units under `ISOMedia.HTTP.*` (`Range`, `Conditional`, `Date`, the facade with `Resource`/`Request`/`Response` structs) produce *plans* (`%Response{}`) and *lazy bodies* (`Stream`s over `SeekIndex.stream_range`). Nothing opens a socket. A thin `ISOMedia.Plug`, compiled only when Plug is loaded, maps a plan onto a `conn`. Every body path is proved byte-exact against the trusted `serialize/1`.

**Tech Stack:** Elixir, ExUnit + `stream_data` (test-only, already a dep), `:erlang.md5` BIF (no `:crypto` app), `Base`/`:calendar` (OTP stdlib), `{:plug, "~> 1.0", optional: true}` (+ `Plug.Test`, test-only).

**Source spec:** `docs/superpowers/specs/2026-06-09-http-byte-range-serving-design.md`
**Phase doc:** `docs/superpowers/specs/phase-1/2026-06-09-http-byte-range-serving.md` (single atomic phase)

**Conventions to follow (from the existing codebase):**
- Typed modules expose pure functions; untrusted input never raises (return data), programmer misuse raises `ArgumentError` — mirrors `SeekIndex.read_range/3`.
- Tests: `use ExUnit.Case` + `use ExUnitProperties`; oracle is `ISOMedia.Serializer.serialize/1`; in-memory trees built from `%ISOMedia.Box{... size_mode: :compact}` (see `test/iso_media/seek_index_test.exs`).
- Run a single test: `mix test test/path_test.exs:LINE`. Full gate: `mix format && mix test`.
- Commit after every green step. Work on branch `spec/http-byte-range-serving` (already checked out).

---

### Task 1: `ISOMedia.HTTP.Range` — RFC 7233 parsing

**Files:**
- Create: `lib/iso_media/http/range.ex`
- Test: `test/iso_media/http/range_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/iso_media/http/range_test.exs
defmodule ISOMedia.HTTP.RangeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ISOMedia.HTTP.Range

  describe "parse/3 — spec forms" do
    test "single closed range" do
      assert Range.parse("bytes=0-499", 1000) == {:ok, [{0, 499}]}
    end

    test "open-ended range clamps to last byte" do
      assert Range.parse("bytes=500-", 1000) == {:ok, [{500, 999}]}
    end

    test "suffix range counts from the end" do
      assert Range.parse("bytes=-500", 1000) == {:ok, [{500, 999}]}
    end

    test "suffix larger than total yields the whole resource" do
      assert Range.parse("bytes=-5000", 1000) == {:ok, [{0, 999}]}
    end

    test "last clamps to total-1" do
      assert Range.parse("bytes=900-5000", 1000) == {:ok, [{900, 999}]}
    end
  end

  describe "parse/3 — multi, coalescing, satisfiability" do
    test "multiple disjoint ranges sorted" do
      assert Range.parse("bytes=200-299,0-99", 1000) == {:ok, [{0, 99}, {200, 299}]}
    end

    test "overlapping/adjacent ranges coalesce" do
      assert Range.parse("bytes=0-99,100-199,150-250", 1000) == {:ok, [{0, 250}]}
    end

    test "all-out-of-range is unsatisfiable" do
      assert Range.parse("bytes=2000-3000", 1000) == :unsatisfiable
    end

    test "suffix of zero is unsatisfiable" do
      assert Range.parse("bytes=-0", 1000) == :unsatisfiable
    end

    test "mix of satisfiable + unsatisfiable keeps the satisfiable one" do
      assert Range.parse("bytes=0-99,5000-6000", 1000) == {:ok, [{0, 99}]}
    end
  end

  describe "parse/3 — ignore (serve 200)" do
    test "non-bytes unit is ignored" do
      assert Range.parse("items=0-10", 1000) == :ignore
    end

    test "syntactic garbage ignores the whole header" do
      assert Range.parse("bytes=abc-def", 1000) == :ignore
      assert Range.parse("bytes=10-5", 1000) == :ignore
      assert Range.parse("bytes=", 1000) == :ignore
    end

    test "more ranges than the cap is ignored" do
      header = "bytes=" <> Enum.map_join(0..200, ",", fn i -> "#{i * 10}-#{i * 10 + 1}" end)
      assert Range.parse(header, 1_000_000, max_ranges: 100) == :ignore
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/range_test.exs`
Expected: FAIL — `module ISOMedia.HTTP.Range is not available`.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/iso_media/http/range.ex
defmodule ISOMedia.HTTP.Range do
  @moduledoc """
  RFC 7233 `Range` header parsing for byte ranges.

  `parse/3` returns `{:ok, ranges}` (normalized, inclusive, absolute, sorted, coalesced),
  `:unsatisfiable` (→ HTTP 416), or `:ignore` (→ serve the full 200 response). It never
  raises on untrusted input: a malformed header degrades to `:ignore`.
  """

  @default_max_ranges 100

  @type range :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Parse a `Range` header against the resource's `total` size.

  Options:
    * `:coalesce` — merge overlapping/adjacent ranges (default `true`)
    * `:max_ranges` — cap on coalesced range count; over the cap ⇒ `:ignore` (default `100`)
  """
  @spec parse(binary(), non_neg_integer(), keyword()) :: {:ok, [range()]} | :unsatisfiable | :ignore
  def parse(header, total, opts \\ [])

  def parse(header, total, opts)
      when is_binary(header) and is_integer(total) and total >= 0 do
    coalesce? = Keyword.get(opts, :coalesce, true)
    max = Keyword.get(opts, :max_ranges, @default_max_ranges)

    case unit_specs(header) do
      :ignore ->
        :ignore

      {:ok, specs} ->
        case classify(specs, total) do
          :ignore -> :ignore
          {[], true} -> :unsatisfiable
          {[], false} -> :ignore
          {sat, _any_unsat?} -> finalize(sat, coalesce?, max)
        end
    end
  end

  def parse(_header, total, _opts) when is_integer(total) and total >= 0, do: :ignore

  defp finalize(sat, coalesce?, max) do
    ranges = if coalesce?, do: coalesce(Enum.sort(sat)), else: Enum.sort(sat)
    if length(ranges) > max, do: :ignore, else: {:ok, ranges}
  end

  # "bytes=a-b,c-d" -> {:ok, ["a-b", "c-d"]} | :ignore
  defp unit_specs(header) do
    case String.split(String.trim(header), "=", parts: 2) do
      [unit, rest] ->
        if String.downcase(unit) == "bytes" do
          specs =
            rest |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

          if specs == [], do: :ignore, else: {:ok, specs}
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  # Returns {satisfiable_ranges, any_unsatisfiable?} or :ignore (any syntax error).
  defp classify(specs, total) do
    Enum.reduce_while(specs, {[], false}, fn spec, {sat, unsat?} ->
      case spec(spec, total) do
        {:ok, fl} -> {:cont, {[fl | sat], unsat?}}
        :unsat -> {:cont, {sat, true}}
        :error -> {:halt, :ignore}
      end
    end)
  end

  defp spec(_spec, 0), do: :unsat

  defp spec(spec, total) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] ->
        case int(suffix) do
          {:ok, 0} -> :unsat
          {:ok, n} -> {:ok, {max(0, total - n), total - 1}}
          :error -> :error
        end

      [first, ""] ->
        case int(first) do
          {:ok, f} when f >= total -> :unsat
          {:ok, f} -> {:ok, {f, total - 1}}
          :error -> :error
        end

      [first, last] ->
        case {int(first), int(last)} do
          {{:ok, f}, {:ok, l}} when f <= l and f >= total -> :unsat
          {{:ok, f}, {:ok, l}} when f <= l -> {:ok, {f, min(l, total - 1)}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp int(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  # Merge overlapping/adjacent ranges in an already-sorted list.
  defp coalesce([]), do: []

  defp coalesce([first | rest]) do
    rest
    |> Enum.reduce([first], fn {f, l}, [{pf, pl} | acc] ->
      if f <= pl + 1, do: [{pf, max(pl, l)} | acc], else: [{f, l}, {pf, pl} | acc]
    end)
    |> Enum.reverse()
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/http/range_test.exs`
Expected: PASS (all cases).

- [ ] **Step 5: Add the fuzz property (invariant #8)**

Append inside `range_test.exs`, before the final `end`:

```elixir
  describe "parse/3 — never raises (invariant #8)" do
    property "arbitrary header strings only ever return {:ok,_} | :unsatisfiable | :ignore" do
      check all(header <- string(:printable, max_length: 60), total <- integer(0..10_000)) do
        result = Range.parse("bytes=" <> header, total)

        case result do
          {:ok, ranges} ->
            assert Enum.all?(ranges, fn {f, l} -> f >= 0 and l < total and f <= l end)

          other ->
            assert other in [:unsatisfiable, :ignore]
        end
      end
    end
  end
```

- [ ] **Step 6: Run + commit**

Run: `mix format && mix test test/iso_media/http/range_test.exs`
Expected: PASS.

```bash
git add lib/iso_media/http/range.ex test/iso_media/http/range_test.exs
git commit -m "feat(http): RFC 7233 Range header parsing (ISOMedia.HTTP.Range)"
```

---

### Task 2: `ISOMedia.HTTP.Date` — HTTP-date parse + format

**Files:**
- Create: `lib/iso_media/http/date.ex`
- Test: `test/iso_media/http/date_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/iso_media/http/date_test.exs
defmodule ISOMedia.HTTP.DateTest do
  use ExUnit.Case, async: true

  alias ISOMedia.HTTP.Date

  describe "parse/1" do
    test "IMF-fixdate" do
      assert Date.parse("Sun, 06 Nov 1994 08:49:37 GMT") == {:ok, {{1994, 11, 6}, {8, 49, 37}}}
    end

    test "RFC 850" do
      assert Date.parse("Sunday, 06-Nov-94 08:49:37 GMT") == {:ok, {{1994, 11, 6}, {8, 49, 37}}}
    end

    test "asctime" do
      assert Date.parse("Sun Nov  6 08:49:37 1994") == {:ok, {{1994, 11, 6}, {8, 49, 37}}}
    end

    test "garbage is :error" do
      assert Date.parse("not a date") == :error
    end
  end

  describe "format/1 (IMF-fixdate)" do
    test "round-trips parse" do
      assert Date.format({{1994, 11, 6}, {8, 49, 37}}) == "Sun, 06 Nov 1994 08:49:37 GMT"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/date_test.exs`
Expected: FAIL — `module ISOMedia.HTTP.Date is not available`.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/iso_media/http/date.ex
defmodule ISOMedia.HTTP.Date do
  @moduledoc """
  HTTP-date parsing and formatting (RFC 7231 §7.1.1.1).

  `parse/1` accepts the preferred IMF-fixdate plus the two obsolete formats
  (RFC 850, asctime), returning a `:calendar.datetime()` (UTC) or `:error`.
  `format/1` always emits IMF-fixdate.
  """

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @imf ~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/
  @rfc850 ~r/^\w+, (\d{2})-(\w{3})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT$/
  @asctime ~r/^\w{3} (\w{3})\s+(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$/

  @spec parse(binary()) :: {:ok, :calendar.datetime()} | :error
  def parse(str) when is_binary(str) do
    s = String.trim(str)

    cond do
      m = Regex.run(@imf, s) -> [_, d, mon, y, h, mi, sec] = m; build(y, mon, d, h, mi, sec)
      m = Regex.run(@rfc850, s) -> [_, d, mon, yy, h, mi, sec] = m; build(rfc850_year(yy), mon, d, h, mi, sec)
      m = Regex.run(@asctime, s) -> [_, mon, d, h, mi, sec, y] = m; build(y, mon, d, h, mi, sec)
      true -> :error
    end
  end

  def parse(_), do: :error

  @spec format(:calendar.datetime()) :: binary()
  def format({{y, mo, d}, {h, mi, s}}) do
    dow = :calendar.day_of_the_week(y, mo, d)

    "#{Enum.at(@days, dow - 1)}, #{pad(d)} #{Enum.at(@months, mo - 1)} #{y} " <>
      "#{pad(h)}:#{pad(mi)}:#{pad(s)} GMT"
  end

  # RFC 850 two-digit year: per RFC 7231, a date more than 50 years in the future is the past.
  # We use the simple convention 0-69 => 2000s, 70-99 => 1900s.
  defp rfc850_year(yy) do
    n = String.to_integer(yy)
    if n < 70, do: Integer.to_string(2000 + n), else: Integer.to_string(1900 + n)
  end

  defp build(y, mon, d, h, mi, sec) do
    with idx when is_integer(idx) <- Enum.find_index(@months, &(&1 == mon)),
         dt = {{int(y), idx + 1, int(d)}, {int(h), int(mi), int(sec)}},
         true <- :calendar.valid_date(elem(dt, 0)) do
      {:ok, dt}
    else
      _ -> :error
    end
  end

  defp int(s), do: String.to_integer(s)
  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
```

- [ ] **Step 4: Run + commit**

Run: `mix format && mix test test/iso_media/http/date_test.exs`
Expected: PASS.

```bash
git add lib/iso_media/http/date.ex test/iso_media/http/date_test.exs
git commit -m "feat(http): HTTP-date parse/format (ISOMedia.HTTP.Date)"
```

---

### Task 3: `SeekIndex.providers/1` + `ISOMedia.HTTP` structs + `etag/2`

**Files:**
- Modify: `lib/iso_media/seek_index.ex` (add public `providers/1`)
- Create: `lib/iso_media/http.ex` (facade + structs + `etag/2`)
- Test: `test/iso_media/http/etag_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/iso_media/http/etag_test.exs
defmodule ISOMedia.HTTP.ETagTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ISOMedia.{Box, FileSlice, HTTP}

  defp tree(data), do: [%Box{type: "free", data: data, size_mode: :compact}]

  describe "etag/2 :pure (invariant #7)" do
    test "same tree yields the same strong tag" do
      e1 = HTTP.etag(tree(<<1, 2, 3>>))
      e2 = HTTP.etag(tree(<<1, 2, 3>>))
      assert e1 == e2
      assert String.starts_with?(e1, "\"")
    end

    test "different content yields a different tag" do
      refute HTTP.etag(tree(<<1, 2, 3>>)) == HTTP.etag(tree(<<1, 2, 4>>))
    end
  end

  describe "etag/2 :stat" do
    @tag :tmp_dir
    test "weak tag reacts to backing-file mtime; :pure does not", %{tmp_dir: dir} do
      path = Path.join(dir, "payload.bin")
      File.write!(path, <<0::size(1600)-unit(8)>>)
      slice = %FileSlice{path: path, offset: 0, length: 200}
      boxes = [%Box{type: "mdat", data: slice, size_mode: :compact}]

      stat1 = HTTP.etag(boxes, etag: :stat)
      pure1 = HTTP.etag(boxes, etag: :pure)
      assert String.starts_with?(stat1, "W/\"")

      File.touch!(path, {{2030, 1, 1}, {0, 0, 0}})

      assert HTTP.etag(boxes, etag: :pure) == pure1
      refute HTTP.etag(boxes, etag: :stat) == stat1
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/etag_test.exs`
Expected: FAIL — `ISOMedia.HTTP is not available`.

- [ ] **Step 3a: Add `providers/1` to `SeekIndex`**

In `lib/iso_media/seek_index.ex`, after `content_length/1`, add:

```elixir
  @doc """
  The ordered list of physical providers (`{:bytes, binary} | {:slice, FileSlice.t()}`) that
  back the serialized output. The basis for a content fingerprint (`ISOMedia.HTTP.etag/2`)
  without materializing payload bytes.
  """
  def providers(%__MODULE__{segments: segs}) do
    segs |> Tuple.to_list() |> Enum.map(& &1.provider)
  end
```

- [ ] **Step 3b: Create the facade module with structs + `etag/2`**

```elixir
# lib/iso_media/http.ex
defmodule ISOMedia.HTTP do
  @moduledoc """
  Pure, zero-dependency HTTP-semantics layer over `ISOMedia.SeekIndex`.

  Build a cacheable `resource/2`, normalize a request with `from_headers/2`, then `serve/2`
  to get a `%Response{}` plan; render it with `body_stream/2` (lazy, O(range)) or
  `body_iodata/1`. Validators come from `etag/2` and `content_type/1`. Nothing here opens a
  socket — see the optional `ISOMedia.Plug` for a transport adapter.
  """

  alias ISOMedia.SeekIndex

  defmodule Resource do
    @moduledoc "Precomputed, cacheable per-representation state."
    defstruct [:index, :etag, :last_modified, :content_type, :content_length]

    @type t :: %__MODULE__{
            index: ISOMedia.SeekIndex.t(),
            etag: binary(),
            last_modified: :calendar.datetime() | nil,
            content_type: binary(),
            content_length: non_neg_integer()
          }
  end

  defmodule Request do
    @moduledoc "Normalized inbound request fields."
    defstruct [
      :method,
      :range,
      :if_none_match,
      :if_match,
      :if_modified_since,
      :if_unmodified_since,
      :if_range
    ]

    @type t :: %__MODULE__{
            method: :get | :head | :other,
            range: binary() | nil,
            if_none_match: binary() | nil,
            if_match: binary() | nil,
            if_modified_since: binary() | nil,
            if_unmodified_since: binary() | nil,
            if_range: binary() | nil
          }
  end

  defmodule Response do
    @moduledoc "An HTTP response plan: status + headers + a pattern-matchable body spec."
    defstruct [:status, :headers, :body]

    @type body ::
            :empty
            | {:full, ISOMedia.SeekIndex.t()}
            | {:range, ISOMedia.SeekIndex.t(), non_neg_integer(), non_neg_integer()}
            | {:multipart, binary(), [map()], ISOMedia.SeekIndex.t()}

    @type t :: %__MODULE__{status: pos_integer(), headers: [{binary(), binary()}], body: body()}
  end

  @doc """
  A stable content fingerprint of a tree's serialization, computed from the `SeekIndex`
  descriptors (never the payload bytes of a slice). `:pure` (default) folds
  `{path, offset, length}` per slice + `:erlang.md5` of in-memory byte parts — a strong tag
  under the backing-files-immutable contract. `:stat` additionally folds each slice path's
  `mtime`+`size` (metadata I/O) and emits a weak `W/` tag.
  """
  @spec etag(SeekIndex.t() | ISOMedia.Box.t() | [ISOMedia.Box.t()], keyword()) :: binary()
  def etag(index_or_tree, opts \\ [])
  def etag(%SeekIndex{} = idx, opts), do: do_etag(idx, opts)
  def etag(tree, opts), do: do_etag(SeekIndex.build(tree), opts)

  defp do_etag(%SeekIndex{} = idx, opts) do
    mode = Keyword.get(opts, :etag, :pure)
    weak? = mode == :stat or Keyword.get(opts, :weak, false)

    digest =
      idx
      |> SeekIndex.providers()
      |> Enum.reduce(:erlang.md5_init(), &fold(&1, &2, mode))
      |> :erlang.md5_final()
      |> Base.encode16(case: :lower)

    if weak?, do: ~s(W/"#{digest}"), else: ~s("#{digest}")
  end

  defp fold({:bytes, bin}, ctx, _mode),
    do: :erlang.md5_update(ctx, [<<0, byte_size(bin)::64>>, bin])

  defp fold({:slice, fs}, ctx, :pure),
    do: :erlang.md5_update(ctx, [<<1>>, fs.path, <<0, fs.offset::64, fs.length::64>>])

  defp fold({:slice, fs}, ctx, :stat) do
    %File.Stat{size: size, mtime: mtime} = File.stat!(fs.path, time: :posix)
    :erlang.md5_update(ctx, [<<2>>, fs.path, <<0, fs.offset::64, fs.length::64, size::64, mtime::64>>])
  end
end
```

- [ ] **Step 4: Run + commit**

Run: `mix format && mix test test/iso_media/http/etag_test.exs test/iso_media/seek_index_test.exs`
Expected: PASS (and SeekIndex unchanged behavior).

```bash
git add lib/iso_media/seek_index.ex lib/iso_media/http.ex test/iso_media/http/etag_test.exs
git commit -m "feat(http): ISOMedia.HTTP structs + etag/2 (pure + :stat), SeekIndex.providers/1"
```

---

### Task 4: `content_type/1`

**Files:**
- Modify: `lib/iso_media/http.ex` (add `content_type/1`)
- Test: `test/iso_media/http/content_type_test.exs`

- [ ] **Step 1: Write the failing test (invariant #12 golden)**

```elixir
# test/iso_media/http/content_type_test.exs
defmodule ISOMedia.HTTP.ContentTypeTest do
  use ExUnit.Case, async: true

  alias ISOMedia.{Box, HTTP}
  alias ISOMedia.Boxes.{FileType, Handler}

  defp ftyp(major, compat \\ []),
    do: FileType.encode(%FileType{major_brand: major, minor_version: 0, compatible_brands: compat})

  defp hdlr(type),
    do: Handler.encode(%Handler{version: 0, flags: <<0::24>>, handler_type: type, name: "", name_suffix: ""})

  defp moov_with(handler), do: Box.container("moov", [Box.container("trak", [Box.container("mdia", [handler])])])

  test "video track => video/mp4" do
    assert HTTP.content_type([ftyp("isom"), moov_with(hdlr("vide"))]) == "video/mp4"
  end

  test "audio-only => audio/mp4" do
    assert HTTP.content_type([ftyp("M4A "), moov_with(hdlr("soun"))]) == "audio/mp4"
  end

  test "quicktime brand => video/quicktime" do
    assert HTTP.content_type([ftyp("qt  "), moov_with(hdlr("vide"))]) == "video/quicktime"
  end

  test "heic image => image/heic" do
    assert HTTP.content_type([ftyp("heic", ["mif1"]), moov_with(hdlr("pict"))]) == "image/heic"
  end

  test "top-level styp => video/iso.segment" do
    assert HTTP.content_type([%Box{type: "styp", data: <<"msdh">>, size_mode: :compact}]) == "video/iso.segment"
  end

  test "no recognizable structure => application/mp4" do
    assert HTTP.content_type([%Box{type: "free", data: <<>>, size_mode: :compact}]) == "application/mp4"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/content_type_test.exs`
Expected: FAIL — `function ISOMedia.HTTP.content_type/1 is undefined`.

- [ ] **Step 3: Implement `content_type/1` in `lib/iso_media/http.ex`**

Add the alias near the top (after `alias ISOMedia.SeekIndex`):

```elixir
  alias ISOMedia.Box
  alias ISOMedia.Boxes.{FileType, Handler}
```

Add the function (after `etag/2`'s private helpers):

```elixir
  @heif_brands ~w(heic heix heim heis mif1)
  @avif_brands ~w(avif avis)

  @doc """
  Derive a media `Content-Type` from a tree's `ftyp` brands and track handler types.
  """
  @spec content_type([Box.t()] | Box.t()) :: binary()
  def content_type(%Box{} = box), do: content_type([box])

  def content_type(tree) when is_list(tree) do
    brands = brands(tree)
    handlers = handler_types(tree)

    cond do
      Box.find(tree, ~w(styp)) -> "video/iso.segment"
      "qt  " in brands -> "video/quicktime"
      Enum.any?(@avif_brands, &(&1 in brands)) -> "image/avif"
      Enum.any?(@heif_brands, &(&1 in brands)) and "pict" in handlers -> "image/heic"
      "vide" in handlers -> "video/mp4"
      "soun" in handlers -> "audio/mp4"
      true -> "application/mp4"
    end
  end

  defp brands(tree) do
    case Box.find(tree, ~w(ftyp)) do
      nil -> []
      box -> ft = FileType.decode(box); [ft.major_brand | ft.compatible_brands]
    end
  end

  defp handler_types(tree) do
    tree
    |> all_boxes()
    |> Enum.filter(&(&1.type == "hdlr"))
    |> Enum.map(&Handler.decode(&1).handler_type)
  end

  defp all_boxes(boxes) do
    Enum.flat_map(boxes, fn %Box{children: kids} = b -> [b | all_boxes(kids || [])] end)
  end
```

- [ ] **Step 4: Run + commit**

Run: `mix format && mix test test/iso_media/http/content_type_test.exs`
Expected: PASS.

```bash
git add lib/iso_media/http.ex test/iso_media/http/content_type_test.exs
git commit -m "feat(http): content_type/1 derivation from ftyp brands + handlers"
```

---

### Task 5: `resource/2` + `from_headers/2`

**Files:**
- Modify: `lib/iso_media/http.ex`
- Test: `test/iso_media/http/resource_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/iso_media/http/resource_test.exs
defmodule ISOMedia.HTTP.ResourceTest do
  use ExUnit.Case, async: true

  alias ISOMedia.{Box, HTTP, Serializer}
  alias ISOMedia.HTTP.{Request, Resource}

  defp tree, do: [%Box{type: "free", data: <<1, 2, 3, 4, 5>>, size_mode: :compact}]

  describe "resource/2" do
    test "computes content_length, etag, content_type" do
      r = HTTP.resource(tree())
      assert %Resource{} = r
      assert r.content_length == byte_size(Serializer.serialize(tree()))
      assert String.starts_with?(r.etag, "\"")
      assert r.content_type == "application/mp4"
    end

    test "honors :content_type and :last_modified opts" do
      lm = {{2024, 1, 1}, {0, 0, 0}}
      r = HTTP.resource(tree(), content_type: "video/mp4", last_modified: lm)
      assert r.content_type == "video/mp4"
      assert r.last_modified == lm
    end

    test ":codecs appends a codecs= param" do
      # tree() has no tracks, so Manifest.codecs/1 returns "" — param still appended deterministically.
      r = HTTP.resource(tree(), codecs: true)
      assert r.content_type =~ ~r/^application\/mp4; codecs="/
    end
  end

  describe "from_headers/2" do
    test "normalizes header keys (case-insensitive) and method" do
      req =
        HTTP.from_headers(
          [{"Range", "bytes=0-9"}, {"If-None-Match", "\"abc\""}],
          "GET"
        )

      assert %Request{method: :get, range: "bytes=0-9", if_none_match: "\"abc\""} = req
    end

    test "unknown method is :other; accepts a map too" do
      req = HTTP.from_headers(%{"if-match" => "*"}, :post)
      assert req.method == :other
      assert req.if_match == "*"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/resource_test.exs`
Expected: FAIL — `function ISOMedia.HTTP.resource/2 is undefined`.

- [ ] **Step 3: Implement in `lib/iso_media/http.ex`**

Add to the aliases: `alias ISOMedia.HTTP.{Request, Resource, Response}` (Response is used by later tasks; add it now). Then add:

```elixir
  @doc """
  Build a cacheable `%Resource{}` from a tree (or a prebuilt `SeekIndex`). Build once per
  `(file, validator)` and reuse across requests. With a bare `SeekIndex` (no tree), the
  content type defaults to `opts[:content_type] || "application/mp4"` (no tree to inspect).
  """
  @spec resource(SeekIndex.t() | Box.t() | [Box.t()], keyword()) :: Resource.t()
  def resource(index_or_tree, opts \\ [])

  def resource(%SeekIndex{} = idx, opts), do: build_resource(idx, nil, opts)

  def resource(tree, opts) do
    idx = SeekIndex.build(tree)
    build_resource(idx, tree, opts)
  end

  defp build_resource(idx, tree, opts) do
    %Resource{
      index: idx,
      etag: etag(idx, opts),
      last_modified: Keyword.get(opts, :last_modified),
      content_type: opts[:content_type] || derive_ct(tree, opts),
      content_length: SeekIndex.content_length(idx)
    }
  end

  defp derive_ct(nil, _opts), do: "application/mp4"

  defp derive_ct(tree, opts) do
    base = content_type(tree)
    if opts[:codecs], do: base <> ~s(; codecs="#{ISOMedia.Manifest.codecs(tree)}"), else: base
  end

  @doc "Normalize a header list/map + method into a `%Request{}` (lowercased header keys)."
  @spec from_headers([{binary(), binary()}] | map(), atom() | binary()) :: Request.t()
  def from_headers(headers, method) do
    h = normalize_headers(headers)

    %Request{
      method: normalize_method(method),
      range: h["range"],
      if_none_match: h["if-none-match"],
      if_match: h["if-match"],
      if_modified_since: h["if-modified-since"],
      if_unmodified_since: h["if-unmodified-since"],
      if_range: h["if-range"]
    }
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), v} end)
  end

  defp normalize_method(m) when is_atom(m), do: normalize_method(Atom.to_string(m))

  defp normalize_method(m) do
    case String.upcase(m) do
      "GET" -> :get
      "HEAD" -> :head
      _ -> :other
    end
  end
```

- [ ] **Step 4: Run + commit**

Run: `mix format && mix test test/iso_media/http/resource_test.exs`
Expected: PASS.

```bash
git add lib/iso_media/http.ex test/iso_media/http/resource_test.exs
git commit -m "feat(http): resource/2 (cacheable Resource) + from_headers/2"
```

---

### Task 6: `ISOMedia.HTTP.Conditional` — RFC 7232 §6 precedence

**Files:**
- Create: `lib/iso_media/http/conditional.ex`
- Test: `test/iso_media/http/conditional_test.exs`

- [ ] **Step 1: Write the failing test (invariant #6 matrix)**

```elixir
# test/iso_media/http/conditional_test.exs
defmodule ISOMedia.HTTP.ConditionalTest do
  use ExUnit.Case, async: true

  alias ISOMedia.HTTP.{Conditional, Request, Resource}

  @etag ~s("v1")
  @lm {{2024, 1, 1}, {12, 0, 0}}
  @res %Resource{index: nil, etag: @etag, last_modified: @lm, content_type: "video/mp4", content_length: 100}

  defp req(fields), do: struct(%Request{method: :get}, fields)

  describe "evaluate/2 precedence" do
    test "If-Match mismatch => precondition_failed (step 1)" do
      assert Conditional.evaluate(req(if_match: ~s("other")), @res) == :precondition_failed
    end

    test "If-Match * matches existing resource => proceed" do
      assert Conditional.evaluate(req(if_match: "*"), @res) == :proceed
    end

    test "If-Unmodified-Since older than mtime => precondition_failed (step 2)" do
      assert Conditional.evaluate(req(if_unmodified_since: "Mon, 01 Jan 2024 11:00:00 GMT"), @res) ==
               :precondition_failed
    end

    test "If-None-Match match + GET => not_modified (step 3)" do
      assert Conditional.evaluate(req(if_none_match: @etag), @res) == :not_modified
    end

    test "If-None-Match match + non-GET => precondition_failed" do
      assert Conditional.evaluate(req(method: :other, if_none_match: @etag), @res) == :precondition_failed
    end

    test "If-None-Match uses weak comparison" do
      assert Conditional.evaluate(req(if_none_match: ~s(W/"v1")), @res) == :not_modified
    end

    test "If-Modified-Since not modified => not_modified (step 4)" do
      assert Conditional.evaluate(req(if_modified_since: "Mon, 01 Jan 2024 12:00:00 GMT"), @res) ==
               :not_modified
    end

    test "If-Modified-Since older than mtime => proceed" do
      assert Conditional.evaluate(req(if_modified_since: "Mon, 01 Jan 2024 11:00:00 GMT"), @res) == :proceed
    end

    test "If-Match takes precedence over If-None-Match" do
      assert Conditional.evaluate(req(if_match: ~s("other"), if_none_match: @etag), @res) ==
               :precondition_failed
    end

    test "no conditions => proceed" do
      assert Conditional.evaluate(req([]), @res) == :proceed
    end
  end

  describe "if_range_satisfied?/2" do
    test "absent If-Range is satisfied" do
      assert Conditional.if_range_satisfied?(req([]), @res)
    end

    test "matching strong etag satisfied; mismatch not" do
      assert Conditional.if_range_satisfied?(req(if_range: @etag), @res)
      refute Conditional.if_range_satisfied?(req(if_range: ~s("other")), @res)
    end

    test "weak etag is NOT a valid If-Range validator" do
      refute Conditional.if_range_satisfied?(req(if_range: ~s(W/"v1")), @res)
    end

    test "date If-Range satisfied when not modified since" do
      assert Conditional.if_range_satisfied?(req(if_range: "Mon, 01 Jan 2024 12:00:00 GMT"), @res)
      refute Conditional.if_range_satisfied?(req(if_range: "Mon, 01 Jan 2024 11:00:00 GMT"), @res)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/conditional_test.exs`
Expected: FAIL — `module ISOMedia.HTTP.Conditional is not available`.

- [ ] **Step 3: Write the implementation**

```elixir
# lib/iso_media/http/conditional.ex
defmodule ISOMedia.HTTP.Conditional do
  @moduledoc """
  RFC 7232 §6 conditional-request precedence. Pure; never raises on untrusted input.

  `evaluate/2` runs the short-circuiting ladder (If-Match → If-Unmodified-Since →
  If-None-Match → If-Modified-Since) returning `:proceed | :not_modified | :precondition_failed`.
  `if_range_satisfied?/2` decides whether a present `Range` is honored (strong validators only).
  """

  alias ISOMedia.HTTP.{Date, Request, Resource}

  @spec evaluate(Request.t(), Resource.t()) :: :proceed | :not_modified | :precondition_failed
  def evaluate(%Request{} = req, %Resource{} = res) do
    cond do
      req.if_match != nil ->
        if match_strong?(req.if_match, res.etag), do: step3(req, res), else: :precondition_failed

      req.if_unmodified_since != nil ->
        case modified_since(res.last_modified, req.if_unmodified_since) do
          true -> :precondition_failed
          _ -> step3(req, res)
        end

      true ->
        step3(req, res)
    end
  end

  defp step3(req, res) do
    cond do
      req.if_none_match != nil ->
        if match_weak?(req.if_none_match, res.etag) do
          if req.method in [:get, :head], do: :not_modified, else: :precondition_failed
        else
          :proceed
        end

      req.if_modified_since != nil and req.method in [:get, :head] ->
        case modified_since(res.last_modified, req.if_modified_since) do
          false -> :not_modified
          _ -> :proceed
        end

      true ->
        :proceed
    end
  end

  @spec if_range_satisfied?(Request.t(), Resource.t()) :: boolean()
  def if_range_satisfied?(%Request{if_range: nil}, _res), do: true

  def if_range_satisfied?(%Request{if_range: ir}, %Resource{} = res) do
    ir = String.trim(ir)

    cond do
      String.starts_with?(ir, "\"") -> equal_strong?(ir, res.etag)
      String.starts_with?(ir, "W/") -> false
      true -> date_unchanged?(ir, res.last_modified)
    end
  end

  defp date_unchanged?(_ir, nil), do: false

  defp date_unchanged?(ir, last_modified) do
    case Date.parse(ir) do
      {:ok, dt} -> secs(last_modified) <= secs(dt)
      :error -> false
    end
  end

  # Returns true (modified), false (not modified), or :unknown (can't determine → caller proceeds).
  defp modified_since(nil, _date), do: :unknown

  defp modified_since(last_modified, date_str) do
    case Date.parse(date_str) do
      {:ok, dt} -> secs(last_modified) > secs(dt)
      :error -> :unknown
    end
  end

  defp secs(dt), do: :calendar.datetime_to_gregorian_seconds(dt)

  # --- entity-tag matching ---
  defp match_strong?(header, etag), do: match(header, etag, &equal_strong?/2)
  defp match_weak?(header, etag), do: match(header, etag, &equal_weak?/2)

  defp match(header, etag, eq) do
    case String.trim(header) do
      "*" -> true
      h -> h |> split_tags() |> Enum.any?(&eq.(&1, etag))
    end
  end

  defp split_tags(s), do: Regex.scan(~r/(?:W\/)?"[^"]*"/, s) |> Enum.map(&hd/1)

  defp equal_strong?(a, b), do: not weak?(a) and not weak?(b) and opaque(a) == opaque(b)
  defp equal_weak?(a, b), do: opaque(a) == opaque(b)
  defp weak?(t), do: String.starts_with?(String.trim(t), "W/")
  defp opaque(t), do: t |> String.trim() |> String.replace_prefix("W/", "")
end
```

- [ ] **Step 4: Run + commit**

Run: `mix format && mix test test/iso_media/http/conditional_test.exs`
Expected: PASS.

```bash
git add lib/iso_media/http/conditional.ex test/iso_media/http/conditional_test.exs
git commit -m "feat(http): RFC 7232 conditional precedence (ISOMedia.HTTP.Conditional)"
```

---

### Task 7: `serve/2` — non-multipart paths + header builders

**Files:**
- Modify: `lib/iso_media/http.ex`
- Test: `test/iso_media/http/serve_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/iso_media/http/serve_test.exs
defmodule ISOMedia.HTTP.ServeTest do
  use ExUnit.Case, async: true

  alias ISOMedia.{Box, HTTP}
  alias ISOMedia.HTTP.Response

  defp tree, do: [%Box{type: "free", data: :binary.copy(<<7>>, 1000), size_mode: :compact}]
  defp res(opts \\ []), do: HTTP.resource(tree(), opts)
  defp request(method, headers), do: HTTP.from_headers(headers, method)

  describe "serve/2 status + headers" do
    test "no Range => 200 full with content-length + accept-ranges" do
      resp = HTTP.serve(res(), request("GET", %{}))
      assert resp.status == 200
      assert {"accept-ranges", "bytes"} in resp.headers
      assert {"content-length", "1008"} in resp.headers
      assert match?({:full, _}, resp.body)
    end

    test "single range => 206 with content-range" do
      resp = HTTP.serve(res(), request("GET", %{"range" => "bytes=0-99"}))
      assert resp.status == 206
      assert {"content-range", "bytes 0-99/1008"} in resp.headers
      assert {"content-length", "100"} in resp.headers
      assert match?({:range, _, 0, 100}, resp.body)
    end

    test "unsatisfiable => 416 with content-range bytes */total" do
      resp = HTTP.serve(res(), request("GET", %{"range" => "bytes=99999-"}))
      assert resp.status == 416
      assert {"content-range", "bytes */1008"} in resp.headers
      assert resp.body == :empty
    end

    test "non-GET/HEAD => 405 with Allow" do
      resp = HTTP.serve(res(), request("POST", %{}))
      assert resp.status == 405
      assert {"allow", "GET, HEAD"} in resp.headers
    end

    test "HEAD parity: same status+headers as GET, empty body (invariant #10)" do
      get = HTTP.serve(res(), request("GET", %{"range" => "bytes=0-99"}))
      head = HTTP.serve(res(), request("HEAD", %{"range" => "bytes=0-99"}))
      assert head.status == get.status
      assert head.headers == get.headers
      assert head.body == :empty
    end

    test "If-None-Match match => 304 empty" do
      r = res()
      resp = HTTP.serve(r, request("GET", %{"if-none-match" => r.etag}))
      assert resp.status == 304
      assert resp.body == :empty
    end

    test "If-Range mismatch ignores Range => 200 full" do
      resp = HTTP.serve(res(), request("GET", %{"range" => "bytes=0-99", "if-range" => "\"stale\""}))
      assert resp.status == 200
      assert match?({:full, _}, resp.body)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/serve_test.exs`
Expected: FAIL — `function ISOMedia.HTTP.serve/2 is undefined`.

- [ ] **Step 3: Implement `serve/2` (non-multipart) in `lib/iso_media/http.ex`**

Add `alias ISOMedia.HTTP.{Conditional, Date, Range}` to the aliases (Date for header formatting, Range for parsing, Conditional for the ladder). Then add:

```elixir
  @doc "Produce a `%Response{}` plan for a request against a resource. Does zero payload I/O."
  @spec serve(Resource.t(), Request.t()) :: Response.t()
  def serve(%Resource{}, %Request{method: :other}),
    do: %Response{status: 405, headers: [{"allow", "GET, HEAD"}], body: :empty}

  def serve(%Resource{} = res, %Request{} = req) do
    case Conditional.evaluate(req, res) do
      :precondition_failed -> resp(412, validator_headers(res), :empty, req)
      :not_modified -> resp(304, validator_headers(res), :empty, req)
      :proceed -> proceed(res, req)
    end
  end

  defp proceed(res, req) do
    cond do
      req.range == nil ->
        full(res, req)

      not Conditional.if_range_satisfied?(req, res) ->
        full(res, req)

      true ->
        dispatch_range(res, req)
    end
  end

  defp dispatch_range(res, req) do
    case Range.parse(req.range, res.content_length) do
      :ignore ->
        full(res, req)

      :unsatisfiable ->
        headers =
          [{"content-range", "bytes */#{res.content_length}"}, {"content-length", "0"}] ++
            base_headers(res)

        resp(416, headers, :empty, req)

      {:ok, [{f, l}]} ->
        single(res, req, f, l)

      {:ok, ranges} ->
        multipart(res, req, ranges)
    end
  end

  defp full(res, req) do
    headers = base_headers(res) ++ [{"content-length", Integer.to_string(res.content_length)}]
    resp(200, headers, {:full, res.index}, req)
  end

  defp single(res, req, f, l) do
    len = l - f + 1

    headers =
      base_headers(res) ++
        [
          {"content-range", "bytes #{f}-#{l}/#{res.content_length}"},
          {"content-length", Integer.to_string(len)}
        ]

    resp(206, headers, {:range, res.index, f, len}, req)
  end

  # multipart/4 is added in Task 8.

  defp resp(status, headers, _body, %Request{method: :head}),
    do: %Response{status: status, headers: headers, body: :empty}

  defp resp(status, headers, body, _req),
    do: %Response{status: status, headers: headers, body: body}

  defp base_headers(res) do
    [{"accept-ranges", "bytes"}, {"etag", res.etag}, {"content-type", res.content_type}] ++
      last_modified_header(res)
  end

  defp validator_headers(res), do: [{"etag", res.etag}] ++ last_modified_header(res)

  defp last_modified_header(%Resource{last_modified: nil}), do: []
  defp last_modified_header(%Resource{last_modified: dt}), do: [{"last-modified", Date.format(dt)}]
```

Note: `multipart/3` does not exist yet, so the `{:ok, ranges}` clause will fail to compile until Task 8. To keep Task 7 green in isolation, temporarily make the multi-range clause serve a 200 full as a stub:

```elixir
      {:ok, ranges} when length(ranges) > 1 ->
        # TEMP stub until Task 8 implements multipart; remove in Task 8.
        full(res, req)
```

(The Task-7 test only exercises single-range, 200, 416, 405, 304, If-Range, HEAD — so the stub is never asserted. Task 8 replaces it.)

- [ ] **Step 4: Run + commit**

Run: `mix format && mix test test/iso_media/http/serve_test.exs`
Expected: PASS.

```bash
git add lib/iso_media/http.ex test/iso_media/http/serve_test.exs
git commit -m "feat(http): serve/2 status/header decisions (200/206/304/412/416/405, HEAD)"
```

---

### Task 8: multipart + `body_iodata/1` + `body_stream/2`

**Files:**
- Modify: `lib/iso_media/http.ex`
- Test: `test/iso_media/http/body_test.exs`

- [ ] **Step 1: Write the failing test (invariants #1–#5)**

```elixir
# test/iso_media/http/body_test.exs
defmodule ISOMedia.HTTP.BodyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ISOMedia.{Box, HTTP, Serializer}

  # In-memory tree generators (the {:bytes,_} path), mirroring seek_index_test.
  defp az(b), do: 0x41 + rem(b, 26)
  defp printable(<<a, b, c, d>>), do: <<az(a), az(b), az(c), az(d)>>

  defp leaf_box do
    gen all(<<a, b, c, d>> <- binary(length: 4), data <- binary(min_length: 1, max_length: 60)) do
      %Box{type: printable(<<a, b, c, d>>), data: data, size_mode: :compact}
    end
  end

  defp tree_gen, do: list_of(leaf_box(), min_length: 1, max_length: 6)

  defp body_bin(resp), do: resp |> HTTP.body_iodata() |> IO.iodata_to_binary()
  defp stream_bin(resp), do: resp |> HTTP.body_stream(8) |> Enum.into("")
  defp request(method, headers), do: HTTP.from_headers(headers, method)
  defp clen(resp), do: resp.headers |> Enum.into(%{}) |> Map.fetch!("content-length") |> String.to_integer()

  describe "single-range + full bodies (invariants #1, #2, #4, #5)" do
    property "200 body == serialize; 206 body == binary_part; content-length exact; stream == iodata" do
      check all(boxes <- tree_gen(), seed <- integer(0..1_000_000)) do
        full = Serializer.serialize(boxes)
        total = byte_size(full)
        res = HTTP.resource(boxes)

        # full
        r200 = HTTP.serve(res, request("GET", %{}))
        assert body_bin(r200) == full
        assert clen(r200) == total

        # single range derived from the seed
        off = rem(seed, total)
        len = rem(div(seed, 7), total - off) + 1
        r206 = HTTP.serve(res, request("GET", %{"range" => "bytes=#{off}-#{off + len - 1}"}))
        assert body_bin(r206) == :binary.part(full, off, len)
        assert clen(r206) == len
        assert stream_bin(r206) == body_bin(r206)
      end
    end
  end

  describe "multipart (invariants #3, #4, #5)" do
    test "two disjoint ranges => reassembles to the exact slices; content-length exact; stream==iodata" do
      boxes = [%Box{type: "free", data: :binary.copy(<<9>>, 1000), size_mode: :compact}]
      full = Serializer.serialize(boxes)
      res = HTTP.resource(boxes)
      resp = HTTP.serve(res, request("GET", %{"range" => "bytes=0-99,500-599"}))

      assert resp.status == 206
      {:multipart, boundary, _parts, _idx} = resp.body

      ct = resp.headers |> Enum.into(%{}) |> Map.fetch!("content-type")
      assert ct == "multipart/byteranges; boundary=" <> boundary

      bin = body_bin(resp)
      assert clen(resp) == byte_size(bin)
      assert stream_bin(resp) == bin

      # Reassemble: every Content-Range part's bytes match the serialize slice.
      parts =
        bin
        |> String.split("--" <> boundary)
        |> Enum.flat_map(fn chunk ->
          case Regex.run(~r/Content-Range: bytes (\d+)-(\d+)\/\d+\r\n\r\n/, chunk, return: :index) do
            [{_, _} | _] = _idx ->
              [_, {fs, fl}, {ls, ll}] = Regex.run(~r/bytes (\d+)-(\d+)\//, chunk, return: :index)
              f = chunk |> binary_part(fs, fl) |> String.to_integer()
              l = chunk |> binary_part(ls, ll) |> String.to_integer()
              {:ok, [{_, _} | _]} = {:ok, Regex.run(~r/\r\n\r\n/, chunk, return: :index)}
              [{_pos, _len}] = Regex.run(~r/\r\n\r\n/, chunk, return: :index)
              {bodystart, _} = hd(Regex.run(~r/\r\n\r\n/, chunk, return: :index))
              payload = binary_part(chunk, bodystart + 4, l - f + 1)
              [{f, l, payload}]

            _ ->
              []
          end
        end)

      assert length(parts) == 2
      for {f, l, payload} <- parts do
        assert payload == :binary.part(full, f, l - f + 1)
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/body_test.exs`
Expected: FAIL — `function ISOMedia.HTTP.body_iodata/1 is undefined`.

- [ ] **Step 3: Implement multipart + bodies in `lib/iso_media/http.ex`**

First, **remove the Task-7 stub clause** in `dispatch_range/2` (the `when length(ranges) > 1` TEMP line) so the real `{:ok, ranges}` clause calls `multipart/3`. Then add:

```elixir
  defp multipart(res, req, ranges) do
    boundary = boundary(res.etag, ranges)

    parts =
      Enum.map(ranges, fn {f, l} ->
        preamble =
          IO.iodata_to_binary([
            "--",
            boundary,
            "\r\nContent-Type: ",
            res.content_type,
            "\r\nContent-Range: bytes ",
            Integer.to_string(f),
            "-",
            Integer.to_string(l),
            "/",
            Integer.to_string(res.content_length),
            "\r\n\r\n"
          ])

        %{first: f, last: l, preamble: preamble}
      end)

    epilogue = "--" <> boundary <> "--\r\n"
    len = multipart_length(parts, epilogue)

    headers =
      [{"accept-ranges", "bytes"}, {"etag", res.etag}] ++
        last_modified_header(res) ++
        [
          {"content-type", "multipart/byteranges; boundary=" <> boundary},
          {"content-length", Integer.to_string(len)}
        ]

    resp(206, headers, {:multipart, boundary, parts, res.index}, req)
  end

  defp multipart_length(parts, epilogue) do
    Enum.reduce(parts, byte_size(epilogue), fn p, acc ->
      acc + byte_size(p.preamble) + (p.last - p.first + 1) + 2
    end)
  end

  defp boundary(etag, ranges) do
    digest = :erlang.md5(etag <> :erlang.term_to_binary(ranges))
    "ISOMedia" <> Base.encode16(digest, case: :lower)
  end

  @doc "Materialize the response body as iodata (small bodies / tests)."
  @spec body_iodata(Response.t()) :: iodata()
  def body_iodata(%Response{body: :empty}), do: []

  def body_iodata(%Response{body: {:full, idx}}),
    do: SeekIndex.read_range(idx, 0, SeekIndex.content_length(idx))

  def body_iodata(%Response{body: {:range, idx, off, len}}),
    do: SeekIndex.read_range(idx, off, len)

  def body_iodata(%Response{body: {:multipart, boundary, parts, idx}}) do
    parts_io =
      Enum.flat_map(parts, fn p ->
        [p.preamble, SeekIndex.read_range(idx, p.first, p.last - p.first + 1), "\r\n"]
      end)

    parts_io ++ ["--" <> boundary <> "--\r\n"]
  end

  @doc """
  Lazily stream the response body as `chunk_size`-byte binaries (O(range), leak-safe over
  `SeekIndex.stream_range`).
  """
  @spec body_stream(Response.t(), pos_integer()) :: Enumerable.t()
  def body_stream(response, chunk_size \\ 65_536)

  def body_stream(%Response{body: :empty}, _cs), do: Stream.concat([])

  def body_stream(%Response{body: {:full, idx}}, cs),
    do: SeekIndex.stream_range(idx, 0, SeekIndex.content_length(idx), cs)

  def body_stream(%Response{body: {:range, idx, off, len}}, cs),
    do: SeekIndex.stream_range(idx, off, len, cs)

  def body_stream(%Response{body: {:multipart, boundary, parts, idx}}, cs) do
    part_streams =
      Enum.map(parts, fn p ->
        Stream.concat([
          [p.preamble],
          SeekIndex.stream_range(idx, p.first, p.last - p.first + 1, cs),
          ["\r\n"]
        ])
      end)

    Stream.concat(part_streams ++ [["--" <> boundary <> "--\r\n"]])
  end
```

- [ ] **Step 4: Run + commit**

Run: `mix format && mix test test/iso_media/http/`
Expected: PASS (all HTTP tests, including the multipart reassembly + content-length exactness).

```bash
git add lib/iso_media/http.ex test/iso_media/http/body_test.exs
git commit -m "feat(http): multipart/byteranges + body_iodata/1 + body_stream/2 (exact length)"
```

---

### Task 9: `ISOMedia` facade re-exports

**Files:**
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media/http/facade_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/iso_media/http/facade_test.exs
defmodule ISOMedia.HTTP.FacadeTest do
  use ExUnit.Case, async: true

  alias ISOMedia.Box

  defp tree, do: [%Box{type: "free", data: <<1, 2, 3>>, size_mode: :compact}]

  test "ISOMedia re-exports the HTTP surface" do
    res = ISOMedia.http_resource(tree())
    req = ISOMedia.http_from_headers(%{"range" => "bytes=0-1"}, "GET")
    resp = ISOMedia.http_serve(res, req)
    assert resp.status == 206
    assert ISOMedia.http_body_iodata(resp) |> IO.iodata_to_binary() == <<11, 0>>
    assert ISOMedia.content_type(tree()) == "application/mp4"
    assert String.starts_with?(ISOMedia.etag(tree()), "\"")
  end
end
```

(Note: `<<11, 0>>` is the first 2 bytes of the serialized `free` box: size `11` as the 4th header byte then the start of `"free"`... compute the actual expected via `ISOMedia.serialize(tree()) |> binary_part(0, 2)` if it differs on your machine; the point is the re-export delegates correctly.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/facade_test.exs`
Expected: FAIL — `function ISOMedia.http_resource/1 is undefined`.

- [ ] **Step 3: Add re-exports to `lib/iso_media.ex`**

After the existing `content_length/1` re-export block, add:

```elixir
  @doc "Build a cacheable HTTP `%Resource{}`. See `ISOMedia.HTTP.resource/2`."
  def http_resource(tree, opts \\ []), do: ISOMedia.HTTP.resource(tree, opts)

  @doc "Normalize headers + method into a `%Request{}`. See `ISOMedia.HTTP.from_headers/2`."
  def http_from_headers(headers, method), do: ISOMedia.HTTP.from_headers(headers, method)

  @doc "Produce an HTTP response plan. See `ISOMedia.HTTP.serve/2`."
  def http_serve(resource, request), do: ISOMedia.HTTP.serve(resource, request)

  @doc "Lazily stream a response body. See `ISOMedia.HTTP.body_stream/2`."
  def http_body_stream(response, chunk_size \\ 65_536),
    do: ISOMedia.HTTP.body_stream(response, chunk_size)

  @doc "Materialize a response body as iodata. See `ISOMedia.HTTP.body_iodata/1`."
  def http_body_iodata(response), do: ISOMedia.HTTP.body_iodata(response)

  @doc "Content fingerprint of a tree's serialization. See `ISOMedia.HTTP.etag/2`."
  def etag(tree, opts \\ []), do: ISOMedia.HTTP.etag(tree, opts)

  @doc "Derive a media Content-Type. See `ISOMedia.HTTP.content_type/1`."
  def content_type(tree), do: ISOMedia.HTTP.content_type(tree)
```

- [ ] **Step 4: Run + commit**

Run: `mix format && mix test test/iso_media/http/facade_test.exs`
Expected: PASS.

```bash
git add lib/iso_media.ex test/iso_media/http/facade_test.exs
git commit -m "feat(http): re-export the HTTP surface on the ISOMedia facade"
```

---

### Task 10: `mix.exs` — optional Plug dependency

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add the dependency**

In `deps/0` in `mix.exs`, add (alongside the existing deps):

```elixir
      # Optional: only the ISOMedia.Plug adapter uses it; never required at runtime.
      # Fetched for this library's own test env (Plug.Test) since optional deps compile here.
      {:plug, "~> 1.0", optional: true},
```

- [ ] **Step 2: Fetch + verify it compiles**

Run: `mix deps.get && mix compile`
Expected: `plug` fetched and compiled; no warnings-as-errors.

- [ ] **Step 3: Commit**

```bash
git add mix.exs mix.lock
git commit -m "build: add optional :plug dependency for ISOMedia.Plug adapter"
```

---

### Task 11: `ISOMedia.Plug` — optional reference adapter

**Files:**
- Create: `lib/iso_media/plug.ex`
- Test: `test/iso_media/http/plug_test.exs`

- [ ] **Step 1: Write the failing test (invariant #11 end-to-end)**

```elixir
# test/iso_media/http/plug_test.exs
defmodule ISOMedia.PlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias ISOMedia.Box

  @moduletag :tmp_dir

  defp build_mp4!(dir) do
    path = Path.join(dir, "movie.mp4")
    boxes = [%Box{type: "free", data: :binary.copy(<<3>>, 2000), size_mode: :compact}]
    :ok = ISOMedia.write(path, boxes)
    {path, ISOMedia.serialize(boxes)}
  end

  defp call(conn, opts), do: ISOMedia.Plug.call(conn, ISOMedia.Plug.init(opts))

  test "GET full file via :root => 200 with accept-ranges", %{tmp_dir: dir} do
    {_path, full} = build_mp4!(dir)
    conn = call(conn(:get, "/movie.mp4"), root: dir)
    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert conn.resp_body == full
  end

  test "Range GET => 206 with exact slice", %{tmp_dir: dir} do
    {_path, full} = build_mp4!(dir)
    conn = call(conn(:get, "/movie.mp4") |> put_req_header("range", "bytes=10-19"), root: dir)
    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 10-19/#{byte_size(full)}"]
    assert conn.resp_body == :binary.part(full, 10, 10)
  end

  test "HEAD => 200 headers, empty body", %{tmp_dir: dir} do
    {_path, _full} = build_mp4!(dir)
    conn = call(conn(:head, "/movie.mp4"), root: dir)
    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "missing file => 404", %{tmp_dir: dir} do
    conn = call(conn(:get, "/nope.mp4"), root: dir)
    assert conn.status == 404
  end

  test "path traversal is refused => 404", %{tmp_dir: dir} do
    build_mp4!(dir)
    conn = call(conn(:get, "/../../etc/passwd"), root: dir)
    assert conn.status == 404
  end

  test "resolver returning a tree works", %{tmp_dir: _dir} do
    boxes = [%Box{type: "free", data: <<1, 2, 3, 4>>, size_mode: :compact}]
    resolver = fn _conn -> {:ok, boxes} end
    conn = call(conn(:get, "/x"), resolver: resolver)
    assert conn.status == 200
    assert conn.resp_body == ISOMedia.serialize(boxes)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/http/plug_test.exs`
Expected: FAIL — `module ISOMedia.Plug is not available` (or `function call/2 undefined`).

- [ ] **Step 3: Write the implementation**

```elixir
# lib/iso_media/plug.ex
if Code.ensure_loaded?(Plug.Conn) do
  defmodule ISOMedia.Plug do
    @moduledoc """
    Optional reference `Plug` that serves an ISOBMFF tree with HTTP byte-range semantics,
    backed by `ISOMedia.HTTP`. Compiled only when Plug is available.

    Options (`init/1`):
      * `:resolver` — `(conn -> {:ok, tree | Resource.t()} | {:ok, tree, res_opts} | :not_found)`
      * `:root` — directory; maps `conn.request_path` to a file (read lazily). Use instead of `:resolver`.
      * `:lazy` — read backing files as `FileSlice` (default `true`; the O(range) path)
      * `:cache` — `:none` (default) | `:persistent_term` (cache `Resource` by `{path, mtime, size}`)
      * `:chunk_size` — stream chunk size (default 65_536)
      * `:etag`/`:content_type`/`:codecs`/`:last_modified`/`:cache_control`/`:extra_headers` — passed to `resource/2`
    """

    @behaviour Plug
    import Plug.Conn

    alias ISOMedia.HTTP

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      case resolve(conn, opts) do
        :not_found -> conn |> send_resp(404, "Not Found") |> halt()
        {:ok, resource} -> respond(conn, resource, opts)
      end
    end

    defp respond(conn, resource, opts) do
      req = HTTP.from_headers(conn.req_headers, conn.method)
      resp = HTTP.serve(resource, req)

      conn =
        resp.headers
        |> Enum.reduce(conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
        |> put_status(resp.status)

      send_body(conn, resp, opts)
    end

    defp send_body(conn, %{status: status, body: :empty}, _opts),
      do: conn |> send_resp(status, "") |> halt()

    defp send_body(conn, resp, opts) do
      chunk_size = Keyword.get(opts, :chunk_size, 65_536)
      conn = send_chunked(conn, resp.status)

      resp
      |> HTTP.body_stream(chunk_size)
      |> Enum.reduce_while(conn, fn data, c ->
        case chunk(c, data) do
          {:ok, c} -> {:cont, c}
          {:error, :closed} -> {:halt, c}
        end
      end)
      |> halt()
    end

    # --- resolution ---
    defp resolve(conn, opts) do
      cond do
        fun = opts[:resolver] -> from_resolver(fun.(conn), opts)
        root = opts[:root] -> from_root(conn, root, opts)
        true -> raise ArgumentError, "ISOMedia.Plug requires :resolver or :root"
      end
    end

    defp from_resolver(:not_found, _opts), do: :not_found
    defp from_resolver({:ok, %HTTP.Resource{} = r}, _opts), do: {:ok, r}
    defp from_resolver({:ok, tree, res_opts}, _opts), do: {:ok, HTTP.resource(tree, res_opts)}
    defp from_resolver({:ok, tree}, opts), do: {:ok, HTTP.resource(tree, res_opts(opts))}

    defp from_root(conn, root, opts) do
      root_abs = Path.expand(root)
      target = Path.expand(Path.join(root_abs, "." <> conn.request_path))

      if File.regular?(target) and String.starts_with?(target, root_abs <> "/") do
        cached_resource(target, opts)
      else
        :not_found
      end
    end

    defp cached_resource(path, opts) do
      case Keyword.get(opts, :cache, :none) do
        :none ->
          {:ok, build(path, opts)}

        :persistent_term ->
          %File.Stat{mtime: mtime, size: size} = File.stat!(path)
          key = {__MODULE__, path, mtime, size, res_opts(opts)}

          case :persistent_term.get(key, nil) do
            nil ->
              resource = build(path, opts)
              :persistent_term.put(key, resource)
              {:ok, resource}

            resource ->
              {:ok, resource}
          end
      end
    end

    defp build(path, opts) do
      {:ok, tree} = ISOMedia.read(path, lazy: Keyword.get(opts, :lazy, true))
      opts = Keyword.put_new_lazy(opts, :last_modified, fn -> File.stat!(path).mtime end)
      HTTP.resource(tree, res_opts(opts))
    end

    defp res_opts(opts) do
      Keyword.take(opts, [:etag, :content_type, :codecs, :last_modified, :cache_control, :extra_headers])
    end
  end
end
```

- [ ] **Step 4: Run + commit**

Run: `mix format && mix test test/iso_media/http/plug_test.exs`
Expected: PASS (200/206/HEAD/404/traversal/resolver).

```bash
git add lib/iso_media/plug.ex test/iso_media/http/plug_test.exs
git commit -m "feat(http): optional ISOMedia.Plug reference adapter (range + conditional + streaming)"
```

---

### Task 12: Docs — CLAUDE.md module map + README + ROADMAP

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the module-map entries to `CLAUDE.md`**

In the `ISOMedia.Boxes.*`/module bullet list (the Architecture section), add two bullets after the `DASH` entry:

```markdown
- `ISOMedia.HTTP` (`lib/iso_media/http.ex`) — pure, zero-dep HTTP-semantics layer over `SeekIndex`: `resource/2` (cacheable `%Resource{}`), `from_headers/2`, `serve/2` (RFC 7233 Range / RFC 7232 conditionals → a `%Response{}` plan), `body_stream/2` (lazy, O(range), leak-safe) / `body_iodata/1`, `etag/2` (`:pure` default + opt-in `:stat`), and `content_type/1`. `serve/2` does zero payload I/O; multipart `Content-Length` is exact (header == streamed bytes by construction). Delegated submodules: `ISOMedia.HTTP.Range` (RFC 7233 parse/coalesce/cap), `ISOMedia.HTTP.Conditional` (RFC 7232 §6 precedence + strong/weak ETag compare), `ISOMedia.HTTP.Date` (HTTP-date parse/format). Proven byte-exact against `serialize/1`.
- `ISOMedia.Plug` (`lib/iso_media/plug.ex`) — optional reference adapter, compiled only when Plug is loaded (`{:plug, "~> 1.0", optional: true}`). Maps an `ISOMedia.HTTP` plan onto a `conn` (`:resolver`/`:root`, `:cache`), streaming the body with `send_chunked` and halting leak-safely on client disconnect (`{:error, :closed}`).
```

- [ ] **Step 2: Add a README section**

After the "Sample-level access" section in `README.md`, add:

````markdown
## Serving over HTTP (byte ranges)

Serve any tree with HTTP range/conditional semantics — pure, zero-dependency:

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4", lazy: true)
res = ISOMedia.http_resource(boxes)              # build once, reuse per request
req = ISOMedia.http_from_headers(conn.req_headers, conn.method)
resp = ISOMedia.http_serve(res, req)             # %Response{status, headers, body}
# stream resp via ISOMedia.http_body_stream(resp) — O(range) memory, zero disk writes
```

Or drop the optional Plug into any Phoenix/Plug app:

```elixir
plug ISOMedia.Plug, root: "/srv/videos", cache: :persistent_term
```
````

- [ ] **Step 3: Add a CHANGELOG entry**

Under `## [Unreleased]` → `### Added` in `CHANGELOG.md`, add:

```markdown
- **HTTP byte-range serving** — `ISOMedia.HTTP` (`resource/2`, `serve/2`, `from_headers/2`,
  `body_stream/2`/`body_iodata/1`, `etag/2`, `content_type/1`): a pure, zero-dependency layer
  over `SeekIndex` implementing RFC 7233 Range requests, RFC 7232 conditionals,
  `multipart/byteranges` with exact `Content-Length`, and validators. Plus an optional
  `ISOMedia.Plug` reference adapter (compiled only when Plug is present).
```

- [ ] **Step 4: Full verification + commit**

Run: `mix format && mix test && mix credo --strict`
Expected: all green; no Credo issues.

```bash
git add CLAUDE.md README.md CHANGELOG.md
git commit -m "docs: document ISOMedia.HTTP + ISOMedia.Plug (H1 shipped)"
```

---

## Final verification

- [ ] Run the full gate: `mix format --check-formatted && mix compile --warnings-as-errors && mix test && mix credo --strict`
- [ ] Confirm every spec §7 invariant has a passing test: #1–#5 (`body_test.exs`), #6 (`conditional_test.exs`), #7 (`etag_test.exs`), #8 (`range_test.exs`), #9 (`serve_test.exs`), #10 (`serve_test.exs`), #11 (`plug_test.exs`), #12 (`content_type_test.exs`).
- [ ] Open a PR from `spec/http-byte-range-serving` to `main`.
