# Time-Based Trim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ISOMedia.trim(boxes, start_sec, end_sec)` — losslessly trim every track to a time range, snapping the video start to the preceding keyframe, rebuilding all sample tables + `mdat`, preserving A/V interleave, and updating duration headers — memory-safely.

**Architecture:** `%Sample{}` gains `duration`. `SampleTable` gains table *encoders* (rebuild `stts`/`ctts`/`stsz`/`stss`/`stsc` from kept samples). A shared `MdatSource` (factored out of `Extract`) resolves a byte range to a segment (FileSlice/binary). `ISOMedia.Trim` selects samples per track (dts-based, snap-to-keyframe), groups kept samples into chunk-runs, sorts all runs across tracks by original offset (interleave-preserving), assigns new offsets, rebuilds each track's tables + durations, and emits a segment-list `mdat`.

**Tech Stack:** Elixir 1.19 / OTP 29, ExUnit, StreamData, ffmpeg fixtures.

**Branch:** `feat/trim` (holds the approved spec at `docs/superpowers/specs/2026-06-02-time-based-trim-design.md`).

**Conventions:** end every commit message with the trailer:
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```
Keep the branch format-clean (`mix format`; a `style: mix format` commit is fine).

---

### Task 1: `%Sample{}` gains `duration`; `SampleTable` populates it

**Files:**
- Modify: `lib/iso_media/sample.ex`, `lib/iso_media/sample_table.ex`
- Test: `test/iso_media/sample_test.exs`, `test/iso_media/sample_table_test.exs`

- [ ] **Step 1: Update the failing tests**

In `test/iso_media/sample_test.exs`, change the keys assertion to include `:duration`:

```elixir
  test "has the expected fields with nil defaults" do
    s = %Sample{}

    assert Map.keys(s) |> Enum.sort() ==
             [:__struct__, :chunk_index, :dts, :duration, :index, :offset, :pts, :size, :sync?]
  end
```

In `test/iso_media/sample_table_test.exs`, add a duration assertion to the first test (after the existing `s3` assertion):

```elixir
    assert Enum.map(samples, & &1.duration) == [100, 100, 100]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/iso_media/sample_test.exs test/iso_media/sample_table_test.exs`
Expected: FAIL — keys list lacks `:duration`; `&1.duration` is `nil`.

- [ ] **Step 3: Add the field and populate it**

In `lib/iso_media/sample.ex`, add `:duration` to the defstruct and `@type t`:

```elixir
  defstruct [:index, :chunk_index, :dts, :duration, :pts, :size, :offset, :sync?]

  @type t :: %__MODULE__{
          index: pos_integer(),
          chunk_index: pos_integer(),
          dts: non_neg_integer(),
          duration: non_neg_integer(),
          pts: integer(),
          size: non_neg_integer(),
          offset: non_neg_integer(),
          sync?: boolean()
        }
```

In `lib/iso_media/sample_table.ex`, change `build/1` to compute per-sample durations and thread them into `assemble`. Replace the `dts = decode_dts(...)` line and the `assemble(...)` call, and update `decode_dts` + `assemble`:

```elixir
    durations = decode_durations(stbl, sample_count)
    dts = cumulative(durations)
    ctts = decode_ctts(stbl, sample_count)
    sync = sync_set(stbl)

    assemble(sizes, chunk_offsets, spc, durations, dts, ctts, sync)
  end
```

Replace the existing `decode_dts/2` with `decode_durations/2` + `cumulative/1`:

```elixir
  defp decode_durations(stbl, sample_count) do
    box = dig(stbl, ["stts"]) || raise ArgumentError, "stbl is missing stts"
    {_v, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)
    deltas = for <<n::32, delta::32 <- rest>>, do: {n, delta}
    per_sample = Enum.flat_map(deltas, fn {n, d} -> List.duplicate(d, n) end)

    if length(per_sample) != sample_count,
      do: raise(ArgumentError, "stts describes #{length(per_sample)} samples, expected #{sample_count}")

    per_sample
  end

  defp cumulative(durations) do
    {dts, _} = Enum.map_reduce(durations, 0, fn d, acc -> {acc, acc + d} end)
    dts
  end
```

Replace `assemble/6` with `assemble/7` (adds `durations`):

```elixir
  defp assemble(sizes, chunk_offsets, spc, durations, dts, ctts, sync) do
    chunks = Enum.zip([1..length(chunk_offsets)//1, chunk_offsets, spc])

    {rev, _state} =
      Enum.reduce(chunks, {[], {1, sizes, durations, dts, ctts}}, fn {cidx, coff, n},
                                                                      {acc, {sidx, sz, du, dt, ct}} ->
        {csz, sz2} = Enum.split(sz, n)
        {cdu, du2} = Enum.split(du, n)
        {cdt, dt2} = Enum.split(dt, n)
        {cct, ct2} = Enum.split(ct, n)

        {chunk_acc, _pos, _i} =
          Enum.reduce(Enum.zip([csz, cdu, cdt, cct]), {acc, coff, sidx}, fn {size, dur, d, c},
                                                                            {a, pos, i} ->
            sample = %Sample{
              index: i,
              chunk_index: cidx,
              dts: d,
              duration: dur,
              pts: d + c,
              size: size,
              offset: pos,
              sync?: sync == :all or MapSet.member?(sync, i)
            }

            {[sample | a], pos + size, i + 1}
          end)

        {chunk_acc, {sidx + n, sz2, du2, dt2, ct2}}
      end)

    Enum.reverse(rev)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/iso_media/sample_test.exs test/iso_media/sample_table_test.exs`
Expected: PASS.

- [ ] **Step 5: Full suite + format + commit**

Run: `mix test && mix format && mix format --check-formatted`
Expected: green, clean.

```bash
git add lib/iso_media/sample.ex lib/iso_media/sample_table.ex test/iso_media/sample_test.exs test/iso_media/sample_table_test.exs
git commit -m "feat: add duration to Sample, populated from stts"
```

---

### Task 2: `SampleTable` table encoders

**Files:**
- Modify: `lib/iso_media/sample_table.ex`
- Test: `test/iso_media/sample_table_encode_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/sample_table_encode_test.exs`:

```elixir
defmodule ISOMedia.SampleTableEncodeTest do
  use ExUnit.Case
  alias ISOMedia.SampleTable

  test "build_stts run-length-encodes durations" do
    box = SampleTable.build_stts([100, 100, 40])
    assert box.type == "stts"
    # version/flags(4) + count(2 entries) + {2,100} {1,40}
    assert box.data == <<0, 0, 0, 0, 2::32, 2::32, 100::32, 1::32, 40::32>>
  end

  test "build_stsz writes explicit sizes" do
    box = SampleTable.build_stsz([10, 20, 30])
    assert box.data == <<0, 0, 0, 0, 0::32, 3::32, 10::32, 20::32, 30::32>>
  end

  test "build_ctts returns nil when all offsets are zero" do
    assert SampleTable.build_ctts([0, 0, 0]) == nil
  end

  test "build_ctts (v0) RLEs nonnegative offsets" do
    box = SampleTable.build_ctts([5, 5, 0])
    assert box.type == "ctts"
    assert box.data == <<0, 0, 0, 0, 2::32, 2::32, 5::32, 1::32, 0::32>>
  end

  test "build_ctts (v1) uses signed offsets when any is negative" do
    box = SampleTable.build_ctts([-2, 3])
    assert <<1::8, 0::24, 2::32, 1::32, -2::signed-32, 1::32, 3::signed-32>> = box.data
  end

  test "build_stss writes 1-based sync positions" do
    box = SampleTable.build_stss([1, 4])
    assert box.data == <<0, 0, 0, 0, 2::32, 1::32, 4::32>>
  end

  test "build_stsc RLEs per-chunk sample counts" do
    # chunks (1-based) with counts [3, 3, 1] -> entries {1,3} {3,1}
    box = SampleTable.build_stsc([3, 3, 1])
    assert box.data == <<0, 0, 0, 0, 2::32, 1::32, 3::32, 1::32, 3::32, 1::32, 1::32>>
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/sample_table_encode_test.exs`
Expected: FAIL — `build_stts/1 is undefined`.

- [ ] **Step 3: Add the encoders**

In `lib/iso_media/sample_table.ex`, add (after `build/1`, before the private decoders):

```elixir
  @doc "Encode a `stts` box from a per-sample duration list (run-length encoded)."
  def build_stts(durations) do
    entries = rle(durations)
    body = for {n, d} <- entries, into: <<>>, do: <<n::32, d::32>>
    leaf("stts", <<0, 0, 0, 0, length(entries)::32, body::binary>>)
  end

  @doc "Encode a `stsz` box from explicit per-sample sizes."
  def build_stsz(sizes) do
    body = for s <- sizes, into: <<>>, do: <<s::32>>
    leaf("stsz", <<0, 0, 0, 0, 0::32, length(sizes)::32, body::binary>>)
  end

  @doc "Encode a `ctts` box from per-sample composition offsets, or `nil` if all zero."
  def build_ctts(offsets) do
    cond do
      Enum.all?(offsets, &(&1 == 0)) ->
        nil

      Enum.any?(offsets, &(&1 < 0)) ->
        entries = rle(offsets)
        body = for {n, off} <- entries, into: <<>>, do: <<n::32, off::signed-32>>
        leaf("ctts", <<1::8, 0::24, length(entries)::32, body::binary>>)

      true ->
        entries = rle(offsets)
        body = for {n, off} <- entries, into: <<>>, do: <<n::32, off::32>>
        leaf("ctts", <<0, 0, 0, 0, length(entries)::32, body::binary>>)
    end
  end

  @doc "Encode a `stss` box from 1-based sync sample positions."
  def build_stss(positions) do
    body = for n <- positions, into: <<>>, do: <<n::32>>
    leaf("stss", <<0, 0, 0, 0, length(positions)::32, body::binary>>)
  end

  @doc "Encode a `stsc` box from per-chunk sample counts (chunk order, 1-based chunks)."
  def build_stsc(per_chunk_counts) do
    entries =
      per_chunk_counts
      |> Enum.with_index(1)
      |> Enum.chunk_by(fn {count, _chunk} -> count end)
      |> Enum.map(fn [{count, first_chunk} | _] = _run -> {first_chunk, count} end)

    body = for {first_chunk, count} <- entries, into: <<>>, do: <<first_chunk::32, count::32, 1::32>>
    leaf("stsc", <<0, 0, 0, 0, length(entries)::32, body::binary>>)
  end

  defp rle(values) do
    values |> Enum.chunk_by(& &1) |> Enum.map(fn run -> {length(run), hd(run)} end)
  end

  defp leaf(type, data), do: %ISOMedia.Box{type: type, data: data}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/sample_table_encode_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/sample_table.ex test/iso_media/sample_table_encode_test.exs
git commit -m "feat: SampleTable table encoders (stts/stsz/ctts/stss/stsc)"
```

---

### Task 3: `ISOMedia.MdatSource` (shared) + refactor `Extract`

**Files:**
- Create: `lib/iso_media/mdat_source.ex`
- Modify: `lib/iso_media/extract.ex`
- Test: `test/iso_media/mdat_source_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/mdat_source_test.exs`:

```elixir
defmodule ISOMedia.MdatSourceTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FileSlice, MdatSource}

  test "segment/3 returns binary_part for an eager mdat" do
    # mdat at source_offset 100, 8-byte header, payload <<0..15>>
    payload = for(i <- 0..15, into: <<>>, do: <<i>>)
    mdat = %Box{type: "mdat", data: payload, source_offset: 100, source_size: 8 + 16}
    # absolute offset 108 = payload start; read 4 bytes
    assert MdatSource.segment([mdat], 108, 4) == <<0, 1, 2, 3>>
    assert MdatSource.segment([mdat], 110, 2) == <<2, 3>>
  end

  test "segment/3 returns a FileSlice for a lazy mdat" do
    mdat = %Box{type: "mdat", data: %FileSlice{path: "x", offset: 0, length: 16}, source_offset: 100, source_size: 24}
    assert MdatSource.segment([mdat], 110, 3) == %FileSlice{path: "x", offset: 110, length: 3}
  end

  test "segment/3 raises when offset is outside every mdat" do
    mdat = %Box{type: "mdat", data: <<0, 1, 2, 3>>, source_offset: 100, source_size: 12}
    assert_raise ArgumentError, fn -> MdatSource.segment([mdat], 9999, 2) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/mdat_source_test.exs`
Expected: FAIL — `ISOMedia.MdatSource.segment/3 is undefined`.

- [ ] **Step 3: Create `MdatSource`**

Create `lib/iso_media/mdat_source.ex`:

```elixir
defmodule ISOMedia.MdatSource do
  @moduledoc """
  Resolves an absolute file byte range to a payload segment, given the top-level
  `mdat` boxes of a parsed tree. Returns a `%FileSlice{}` when the containing `mdat`
  is lazy, or a `binary` slice when it is in memory. Shared by `Extract` and `Trim`.
  """

  alias ISOMedia.{Box, FileSlice, Layout}

  @doc "The top-level `mdat` boxes of `boxes`."
  def collect(boxes), do: Enum.filter(boxes, &(&1.type == "mdat"))

  @doc "A segment (FileSlice or binary) for the absolute `offset`..`offset+length` range."
  def segment(mdats, offset, length) do
    mdat =
      Enum.find(mdats, fn m ->
        not is_nil(m.source_offset) and offset >= m.source_offset and
          offset < m.source_offset + m.source_size
      end) || raise ArgumentError, "byte range at offset #{offset} falls outside every mdat"

    case mdat.data do
      %FileSlice{path: path} ->
        %FileSlice{path: path, offset: offset, length: length}

      bin when is_binary(bin) ->
        %Box{} = mdat
        binary_part(bin, offset - (mdat.source_offset + Layout.header_size(mdat)), length)

      _ ->
        raise ArgumentError, "cannot read from an mdat whose payload is already a segment list"
    end
  end
end
```

- [ ] **Step 4: Refactor `Extract` to use it**

In `lib/iso_media/extract.ex`, replace the private `segment_for/3` definition with a thin delegation, and update its call site. Change the alias line to drop `FileSlice` if now unused (keep `Box, Layout`), add `alias ISOMedia.MdatSource`. Replace the `segments = Enum.map(runs, fn {off, len} -> segment_for(mdats, off, len) end)` line's helper: delete the whole `defp segment_for(mdats, offset, length) do ... end` and change the call to:

```elixir
    segments = Enum.map(runs, fn {off, len} -> MdatSource.segment(mdats, off, len) end)
```

(Behavior is identical — `MdatSource.segment/3` is the extracted logic. If the compiler warns `FileSlice`/`Layout` is now unused in `extract.ex`, remove it from the alias.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/iso_media/mdat_source_test.exs test/iso_media/extract_test.exs test/iso_media/extract_av_test.exs test/iso_media/extract_property_test.exs`
Expected: PASS — `MdatSource` works and extraction is unchanged.

- [ ] **Step 6: Full suite + format + commit**

Run: `mix test && mix format && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: green, clean, no warnings.

```bash
git add lib/iso_media/mdat_source.ex lib/iso_media/extract.ex test/iso_media/mdat_source_test.exs
git commit -m "refactor: extract MdatSource segment helper (shared by Extract/Trim)"
```

---

### Task 4: `MP4Builder` — per-sample durations + sync flags

**Files:**
- Modify: `test/support/mp4_builder.ex`
- Test: `test/iso_media/mp4_builder_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/mp4_builder_test.exs`:

```elixir
  test "build_tracks honors per-sample duration and sync flags" do
    # Track 1: one chunk of 3 samples; durations 100/100/40; samples 1 & 3 sync.
    specs = [
      %{
        id: 1,
        chunks: [[<<1>>, <<2, 2>>, <<3>>]],
        durations: [100, 100, 40],
        sync: [1, 3]
      }
    ]

    %{binary: bin} = ISOMedia.Support.MP4Builder.build_tracks(specs)
    {:ok, boxes} = ISOMedia.parse(bin)
    samples = ISOMedia.samples(boxes, 1)

    assert Enum.map(samples, & &1.duration) == [100, 100, 40]
    assert Enum.map(samples, & &1.sync?) == [true, false, true]
  end

  test "build_tracks defaults: duration 1, all sync (back-compat)" do
    %{binary: bin} = ISOMedia.Support.MP4Builder.build_tracks([%{id: 1, chunks: [[<<1>>, <<2>>]]}])
    {:ok, boxes} = ISOMedia.parse(bin)
    samples = ISOMedia.samples(boxes, 1)
    assert Enum.map(samples, & &1.duration) == [1, 1]
    assert Enum.all?(samples, & &1.sync?)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/mp4_builder_test.exs`
Expected: FAIL — durations are all 1 / no stss support yet.

- [ ] **Step 3: Extend `build_tracks` / `trak`**

In `test/support/mp4_builder.ex`, replace the `trak/2` function (and add a `stss` helper) so a spec may carry `:durations` (per sample, in flattened sample order) and `:sync` (1-based sync sample numbers). Defaults keep the old behavior (duration 1, all sync = no stss):

```elixir
  defp trak(spec, chunk_offsets) do
    sample_sizes = spec.chunks |> List.flatten() |> Enum.map(&byte_size/1)
    spc = Enum.map(spec.chunks, &length/1)
    n = length(sample_sizes)
    durations = Map.get(spec, :durations, List.duplicate(1, n))
    sync = Map.get(spec, :sync, nil)

    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = stts_box(durations)
    stsc = stsc_box(spc)
    stsz = leaf("stsz", <<0, 0, 0, 0, 0::32, n::32, sizes_bin(sample_sizes)::binary>>)
    stco = leaf("stco", <<0, 0, 0, 0, length(chunk_offsets)::32, offsets_bin(chunk_offsets)::binary>>)
    stss = if sync, do: stss_box(sync), else: <<>>
    stbl = container("stbl", stsd <> stts <> stsc <> stsz <> stco <> stss)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, spec.id::32, 0::32, 0::32>>)
    container("trak", tkhd <> container("mdia", container("minf", stbl)))
  end

  defp stts_box(durations) do
    entries =
      durations
      |> Enum.chunk_by(& &1)
      |> Enum.map(fn run -> <<length(run)::32, hd(run)::32>> end)
      |> IO.iodata_to_binary()

    count = durations |> Enum.chunk_by(& &1) |> length()
    leaf("stts", <<0, 0, 0, 0, count::32, entries::binary>>)
  end

  defp stss_box(sync) do
    entries = for n <- sync, into: <<>>, do: <<n::32>>
    leaf("stss", <<0, 0, 0, 0, length(sync)::32, entries::binary>>)
  end
```

(The existing `trak/2` had a fixed `stts` of `<<...1::32, n::32, 1::32>>` and no `stss`; this replaces it. `stss_box`/`stts_box` are new; everything else in `MP4Builder` is unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/mp4_builder_test.exs`
Expected: PASS (existing builder tests + the 2 new ones).

- [ ] **Step 5: Commit**

```bash
git add test/support/mp4_builder.ex test/iso_media/mp4_builder_test.exs
git commit -m "test: MP4Builder per-sample durations + sync flags"
```

---

### Task 5: `ISOMedia.Trim.trim/3` + `ISOMedia.trim/3`

**Files:**
- Create: `lib/iso_media/trim.ex`
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media/trim_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/trim_test.exs`:

```elixir
defmodule ISOMedia.TrimTest do
  use ExUnit.Case

  # Two tracks, each 4 samples in two chunks of 2, duration 100 each (timescale via mdhd).
  # MP4Builder doesn't emit mdhd, so trim falls back to timescale 1 (durations are the units).
  defp build do
    specs = [
      %{id: 1, chunks: [[<<1, 1>>, <<2, 2>>], [<<3, 3>>, <<4, 4>>]], durations: [10, 10, 10, 10], sync: [1, 3]},
      %{id: 2, chunks: [[<<5>>, <<6>>], [<<7>>, <<8>>]], durations: [10, 10, 10, 10]}
    ]

    %{binary: bin} = ISOMedia.Support.MP4Builder.build_tracks(specs)
    {:ok, boxes} = ISOMedia.parse(bin)
    {bin, boxes}
  end

  test "trim keeps samples in range and re-bases the timeline to 0" do
    {_bin, boxes} = build()
    # timescale defaults to 1 (no mdhd), so seconds == duration units. Keep dts in [10, 30).
    out = boxes |> ISOMedia.trim(10, 30) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    s1 = ISOMedia.samples(reparsed, 1)
    # track 1 sync samples at dts 0 and 20; start 10 snaps back to keyframe at dts 0 (sample 1).
    # kept: samples with dts in [0(snap)..<30] = samples 1,2,3 (dts 0,10,20).
    assert Enum.map(s1, & &1.dts) == [0, 10, 20]
    assert Enum.map(s1, &binary_part(out, &1.offset, &1.size)) == [<<1, 1>>, <<2, 2>>, <<3, 3>>]
    # re-based: first dts is 0
    assert hd(s1).dts == 0
  end

  test "trim preserves A/V interleave (chunks sorted by original offset)" do
    {_bin, boxes} = build()
    out = boxes |> ISOMedia.trim(0, 40) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    # gather all chunk offsets across both tracks from the OUTPUT; they must be strictly ascending
    # in the order the runs were written (interleave preserved, not block-per-track).
    offs =
      for id <- ISOMedia.track_ids(reparsed),
          trak = Enum.find(Enum.find(reparsed, &(&1.type == "moov")).children, &(ISOMedia.Boxes.TrackHeader.decode(ISOMedia.Box.find([&1], ~w(trak tkhd))).track_id == id)),
          stco = ISOMedia.Box.find([trak], ~w(trak mdia minf stbl stco)),
          o <- ISOMedia.Boxes.ChunkOffset.decode(stco).offsets,
          do: o

    # both tracks' chunks land in the shared mdat; the full set is all distinct and in-range
    assert length(offs) == length(Enum.uniq(offs))
  end

  test "every kept sample's bytes are byte-identical to the original" do
    {bin, boxes} = build()
    out = boxes |> ISOMedia.trim(0, 40) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)
    {:ok, orig} = ISOMedia.parse(bin)

    for id <- ISOMedia.track_ids(reparsed) do
      orig_bytes = ISOMedia.samples(orig, id) |> Enum.map(&binary_part(bin, &1.offset, &1.size))
      new_bytes = ISOMedia.samples(reparsed, id) |> Enum.map(&binary_part(out, &1.offset, &1.size))
      assert new_bytes == orig_bytes
    end
  end

  test "raises when end <= start" do
    {_bin, boxes} = build()
    assert_raise ArgumentError, fn -> ISOMedia.trim(boxes, 30, 10) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/trim_test.exs`
Expected: FAIL — `ISOMedia.trim/3 is undefined`.

- [ ] **Step 3: Implement `Trim`**

Create `lib/iso_media/trim.ex`:

```elixir
defmodule ISOMedia.Trim do
  @moduledoc """
  Losslessly trim every track to a time range `[start_sec, end_sec)`.

  Per track: select samples by decode time (snap the start back to the nearest
  keyframe), rebuild all sample tables from the kept set, and re-base the timeline to
  zero. Kept chunk-runs from all tracks are written to a new `mdat` sorted by their
  original file offset, preserving A/V interleave. Duration headers are updated.
  Memory-safe: the new `mdat` is a segment list.
  """

  alias ISOMedia.{Box, Layout, MdatSource, SampleTable}
  alias ISOMedia.Boxes.{ChunkOffset, MediaHeader, MovieHeader, TrackHeader}

  @uint32_max 0xFFFFFFFF

  @doc "Trim every track to `[start_sec, end_sec)`. Returns a new box tree."
  def trim(boxes, start_sec, end_sec) do
    if end_sec <= start_sec, do: raise(ArgumentError, "trim: end_sec must be > start_sec")

    ftyp = Enum.find(boxes, &(&1.type == "ftyp")) || raise ArgumentError, "file has no ftyp"
    moov = Enum.find(boxes, &(&1.type == "moov")) || raise ArgumentError, "file has no moov"
    mdats = MdatSource.collect(boxes)
    movie_ts = MovieHeader.decode(dig(moov, ["mvhd"])).timescale

    selections =
      moov.children
      |> Enum.filter(&(&1.type == "trak"))
      |> Enum.map(fn trak -> select_track(trak, start_sec, end_sec) end)

    # Tag each kept chunk-run with its track index and original offset, then sort
    # globally by original offset to preserve interleave.
    tagged =
      selections
      |> Enum.with_index()
      |> Enum.flat_map(fn {sel, ti} ->
        Enum.map(sel.runs, fn run ->
          %{track_i: ti, offset: hd(run).offset, length: Enum.sum(Enum.map(run, & &1.size)), samples: run}
        end)
      end)
      |> Enum.sort_by(& &1.offset)

    total = Enum.sum(Enum.map(tagged, & &1.length))
    {mdat_mode, mdat_header} = if 8 + total > @uint32_max, do: {:large, 16}, else: {:compact, 8}

    runs_per_track = Map.new(Enum.with_index(selections), fn {sel, ti} -> {ti, length(sel.runs)} end)
    dummy = fn -> Map.new(runs_per_track, fn {ti, n} -> {ti, List.duplicate(0, n)} end) end

    # Decide co64 vs stco from a conservative upper bound (co64 tables + 16-byte header).
    bound =
      Layout.box_size(ftyp) + Layout.box_size(assemble_moov(moov, selections, dummy.(), :co64, movie_ts)) +
        16 + total

    co_kind = if bound > @uint32_max, do: :co64, else: :stco

    moov0 = assemble_moov(moov, selections, dummy.(), co_kind, movie_ts)
    mdat_payload_start = Layout.box_size(ftyp) + Layout.box_size(moov0) + mdat_header

    {placed, _} =
      Enum.map_reduce(tagged, mdat_payload_start, fn run, pos ->
        {Map.put(run, :new_offset, pos), pos + run.length}
      end)

    offsets_by_track =
      Map.new(0..(length(selections) - 1)//1, fn ti ->
        offs = placed |> Enum.filter(&(&1.track_i == ti)) |> Enum.map(& &1.new_offset)
        {ti, offs}
      end)

    moov_final = assemble_moov(moov, selections, offsets_by_track, co_kind, movie_ts)
    segments = Enum.map(placed, fn run -> MdatSource.segment(mdats, run.offset, run.length) end)
    mdat = %Box{type: "mdat", data: segments, size_mode: mdat_mode}

    [ftyp, moov_final, mdat]
  end

  # --- per-track selection ---

  defp select_track(trak, start_sec, end_sec) do
    ts = MediaHeader.decode(dig(trak, ~w(mdia mdhd))).timescale
    start_ts = round(start_sec * ts)
    end_ts = round(end_sec * ts)

    samples = SampleTable.build(trak)

    start_index =
      case Enum.filter(samples, fn s -> s.sync? and s.dts <= start_ts end) do
        [] -> 1
        syncs -> List.last(syncs).index
      end

    kept = Enum.filter(samples, fn s -> s.index >= start_index and s.dts < end_ts end)

    if kept == [],
      do: raise(ArgumentError, "trim range selects no samples for track #{track_id(trak)}")

    %{trak: trak, ts: ts, kept: kept, runs: Enum.chunk_by(kept, & &1.chunk_index)}
  end

  # --- moov / trak rebuild ---

  defp assemble_moov(moov, selections, offsets_by_track, co_kind, movie_ts) do
    trimmed =
      selections
      |> Enum.with_index()
      |> Enum.map(fn {sel, ti} ->
        build_trimmed_trak(sel, Map.fetch!(offsets_by_track, ti), co_kind, movie_ts)
      end)

    movie_dur =
      selections
      |> Enum.map(fn sel -> scale(sum_durations(sel.kept), sel.ts, movie_ts) end)
      |> Enum.max(fn -> 0 end)

    children =
      moov.children
      |> drop_traks()
      |> Enum.map(fn
        %Box{type: "mvhd"} = mvhd -> set_mvhd_duration(mvhd, movie_dur)
        other -> other
      end)

    %{moov | children: insert_traks(children, trimmed)}
  end

  defp build_trimmed_trak(sel, stco_offsets, co_kind, movie_ts) do
    kept = sel.kept
    track_dur = sum_durations(kept)

    stsd = dig(sel.trak, ~w(mdia minf stbl stsd)) || raise ArgumentError, "trak missing stsd"
    stts = SampleTable.build_stts(Enum.map(kept, & &1.duration))
    ctts = SampleTable.build_ctts(Enum.map(kept, &(&1.pts - &1.dts)))
    stsz = SampleTable.build_stsz(Enum.map(kept, & &1.size))
    stsc = SampleTable.build_stsc(Enum.map(sel.runs, &length/1))
    stco = ChunkOffset.encode(%ChunkOffset{kind: co_kind, version: 0, flags: <<0, 0, 0>>, offsets: stco_offsets})
    stss = sync_box(kept)

    stbl_children =
      [stsd, stts] ++ opt(ctts) ++ [stsc, stsz] ++ opt(stss) ++ [stco]

    sel.trak
    |> put_stbl(stbl_children)
    |> update_descendant(~w(mdia mdhd), &set_mdhd_duration(&1, track_dur))
    |> update_descendant(["tkhd"], &set_tkhd_duration(&1, scale(track_dur, sel.ts, movie_ts)))
  end

  # stss only when not every kept sample is sync.
  defp sync_box(kept) do
    if Enum.all?(kept, & &1.sync?) do
      nil
    else
      positions =
        kept |> Enum.with_index(1) |> Enum.filter(fn {s, _} -> s.sync? end) |> Enum.map(&elem(&1, 1))

      SampleTable.build_stss(positions)
    end
  end

  defp put_stbl(trak, stbl_children) do
    update_descendant(trak, ~w(mdia minf stbl), fn stbl -> %{stbl | children: stbl_children} end)
  end

  defp set_mdhd_duration(mdhd, dur) do
    h = MediaHeader.decode(mdhd)
    MediaHeader.encode(%{h | duration: dur})
  end

  defp set_tkhd_duration(tkhd, dur) do
    h = TrackHeader.decode(tkhd)
    TrackHeader.encode(%{h | duration: dur})
  end

  defp set_mvhd_duration(mvhd, dur) do
    h = MovieHeader.decode(mvhd)
    MovieHeader.encode(%{h | duration: dur})
  end

  # --- small helpers ---

  defp sum_durations(samples), do: Enum.sum(Enum.map(samples, & &1.duration))
  defp scale(value, from_ts, to_ts), do: round(value * to_ts / from_ts)
  defp opt(nil), do: []
  defp opt(box), do: [box]

  defp drop_traks(children), do: Enum.reject(children, &(&1.type == "trak"))

  # Re-insert trimmed traks where the first trak was (after mvhd, before udta etc.).
  defp insert_traks(children, traks) do
    idx = Enum.find_index(children, &(&1.type == "mvhd"))
    at = if idx, do: idx + 1, else: 0
    {pre, post} = Enum.split(children, at)
    pre ++ traks ++ post
  end

  defp track_id(trak), do: TrackHeader.decode(dig(trak, ["tkhd"])).track_id

  defp dig(%Box{type: type} = box, path), do: Box.find([box], [type | path])

  defp update_descendant(box, [], fun), do: fun.(box)

  defp update_descendant(%Box{children: children} = box, [type | rest], fun) do
    new_children =
      Enum.map(children, fn
        %Box{type: ^type} = c -> update_descendant(c, rest, fun)
        other -> other
      end)

    %{box | children: new_children}
  end
end
```

- [ ] **Step 4: Add the public delegation**

In `lib/iso_media.ex`, add (after `extract_track/2`):

```elixir
  @doc "Losslessly trim every track to the time range `[start_sec, end_sec)`."
  def trim(boxes, start_sec, end_sec), do: ISOMedia.Trim.trim(boxes, start_sec, end_sec)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/iso_media/trim_test.exs`
Expected: PASS (4 tests). (If a byte/dts assertion fails, the selection or table rebuild is wrong — debug `Trim`/`SampleTable`, do not weaken. Note: `MediaHeader.decode` on a track with no `mdhd` will fail — `MP4Builder` traks have no `mdhd`, so this test relies on the builder; if `select_track` raises on missing `mdhd`, make `MP4Builder.trak` emit a minimal `mdhd` with timescale — see note below.)

**Note for the implementer:** `MP4Builder`'s `trak` currently emits no `mdhd`, but `Trim.select_track` reads `mdhd` for the timescale. Add a minimal `mdhd` to `MP4Builder.trak/2` so built tracks have a timescale of 1:
```elixir
    mdhd = leaf("mdhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::16, 0::16>>)
    mdia = container("mdia", mdhd <> container("minf", stbl))
```
(version 0 mdhd: creation/modification(32 each), timescale=1(32), duration=0(32), language(16), pre_defined(16)). Replace the existing `container("mdia", container("minf", stbl))` line in `trak/2` with the two lines above. Commit this with Task 5 (it's required for trim to work on built files). The real `sample_av.mp4` already has `mdhd`s.

- [ ] **Step 6: Full suite + format + commit**

Run: `mix test && mix format && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: green, clean, no warnings.

```bash
git add lib/iso_media/trim.ex lib/iso_media.ex test/iso_media/trim_test.exs test/support/mp4_builder.ex
git commit -m "feat: time-based trim/3 (interleave-preserving, table rebuild, duration update)"
```

---

### Task 6: Keyframe snap + real `sample_av.mp4` integration

**Files:**
- Test: `test/iso_media/trim_av_test.exs`

- [ ] **Step 1: Write the integration test**

Create `test/iso_media/trim_av_test.exs`:

```elixir
defmodule ISOMedia.TrimAvTest do
  use ExUnit.Case

  @fixture Path.join([__DIR__, "..", "fixtures", "sample_av.mp4"])

  defp tmp, do: Path.join(System.tmp_dir!(), "iso_trim_#{System.unique_integer([:positive])}.mp4")

  test "trim keeps both tracks, samples byte-identical, timeline re-based" do
    original = File.read!(@fixture)
    {:ok, boxes} = ISOMedia.parse(original)

    out = boxes |> ISOMedia.trim(0.2, 0.8) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    assert length(ISOMedia.track_ids(reparsed)) == 2

    for id <- ISOMedia.track_ids(reparsed) do
      samples = ISOMedia.samples(reparsed, id)
      assert samples != []
      # re-based: first sample starts at dts 0
      assert hd(samples).dts == 0
      # every kept sample resolves to real bytes inside the output
      assert Enum.all?(samples, &(&1.offset + &1.size <= byte_size(out)))
      # the first sample of a track that has sync samples must be a keyframe
      assert hd(samples).sync?
    end
  end

  test "trim start snaps back to a keyframe (first kept sample is sync)" do
    {:ok, boxes} = ISOMedia.parse(File.read!(@fixture))
    # video track 1 has sparse keyframes; trim from a mid-clip point
    out = boxes |> ISOMedia.trim(0.5, 0.9) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)
    assert hd(ISOMedia.samples(reparsed, 1)).sync?
  end

  test "lazy trim streams and matches eager" do
    {:ok, eager} = ISOMedia.parse(File.read!(@fixture))
    eager_out = eager |> ISOMedia.trim(0.2, 0.8) |> ISOMedia.serialize()

    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    out = tmp()
    on_exit(fn -> File.rm(out) end)
    assert :ok = ISOMedia.write(out, ISOMedia.trim(lazy, 0.2, 0.8))
    assert File.read!(out) == eager_out
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/iso_media/trim_av_test.exs`
Expected: PASS (3 tests). (If a real-file assertion fails, the trim math is wrong on real data — debug, do not weaken. If `trim(lazy)` doesn't match eager, the segment ordering/offset math differs between paths.)

- [ ] **Step 3: Commit**

```bash
git add test/iso_media/trim_av_test.exs
git commit -m "test: real 2-track trim integration (keyframe snap, lazy==eager)"
```

---

### Task 7: Property test + docs

**Files:**
- Create: `test/iso_media/trim_property_test.exs`
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Write the property test**

Create `test/iso_media/trim_property_test.exs`:

```elixir
defmodule ISOMedia.TrimPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Support.MP4Builder

  # A track: 1..3 chunks of 1..3 samples (1..6 bytes), uniform duration 10, all sync.
  defp track_gen(id) do
    gen all(chunks <- list_of(list_of(binary(min_length: 1, max_length: 6), min_length: 1, max_length: 3), min_length: 1, max_length: 3)) do
      n = chunks |> List.flatten() |> length()
      %{id: id, chunks: chunks, durations: List.duplicate(10, n)}
    end
  end

  defp movie do
    gen all(t1 <- track_gen(1), t2 <- track_gen(2)) do
      specs = [t1, t2]
      %{specs: specs, binary: MP4Builder.build_tracks(specs).binary}
    end
  end

  property "trimming [0, big) keeps all samples byte-identical and re-parses to the same tracks" do
    check all(%{binary: bin} <- movie()) do
      {:ok, boxes} = ISOMedia.parse(bin)
      {:ok, orig} = ISOMedia.parse(bin)

      out = boxes |> ISOMedia.trim(0, 1_000_000) |> ISOMedia.serialize()
      {:ok, reparsed} = ISOMedia.parse(out)

      assert ISOMedia.track_ids(reparsed) == ISOMedia.track_ids(orig)

      for id <- ISOMedia.track_ids(reparsed) do
        orig_bytes = ISOMedia.samples(orig, id) |> Enum.map(&binary_part(bin, &1.offset, &1.size))
        new_bytes = ISOMedia.samples(reparsed, id) |> Enum.map(&binary_part(out, &1.offset, &1.size))
        assert new_bytes == orig_bytes
      end
    end
  end

  property "lazy trim-write == eager trim-serialize" do
    check all(%{binary: bin} <- movie()) do
      path = Path.join(System.tmp_dir!(), "iso_tp_#{System.unique_integer([:positive])}.mp4")
      out = Path.join(System.tmp_dir!(), "iso_tpo_#{System.unique_integer([:positive])}.mp4")
      File.write!(path, bin)

      try do
        {:ok, eager} = ISOMedia.read(path)
        eager_out = eager |> ISOMedia.trim(0, 1_000_000) |> ISOMedia.serialize()
        {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)
        :ok = ISOMedia.write(out, ISOMedia.trim(lazy, 0, 1_000_000))
        assert File.read!(out) == eager_out
      after
        File.rm(path)
        File.rm(out)
      end
    end
  end
end
```

- [ ] **Step 2: Run the property suite**

Run: `mix test test/iso_media/trim_property_test.exs`
Expected: PASS (2 properties). (A failure is a real trim/offset bug — StreamData shrinks; debug, don't weaken.)

- [ ] **Step 3: Update the README**

In `README.md`, add after the "Sample-level access" section:

```markdown
## Trim

Losslessly trim every track to a time range (no re-encode). The video start snaps
back to the nearest keyframe so the result decodes; the timeline re-bases to 0 and
A/V interleave is preserved:

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")
ISOMedia.write("clip.mp4", ISOMedia.trim(boxes, 10.0, 25.0))   # keep 10s..25s
```

`trim/3` rebuilds each track's sample tables and `mdat` and updates the duration
headers. Frame-accurate start (an `elst` to hide the leading frames before the
requested point) and concatenation are future phases.
```

- [ ] **Step 4: Update CLAUDE.md**

In `CLAUDE.md`, add to the `## Architecture` module list:

```markdown
- `ISOMedia.MdatSource` (`lib/iso_media/mdat_source.ex`) — resolves an absolute byte range to a payload segment (FileSlice/binary) via the containing `mdat`; shared by `Extract` and `Trim`.
- `ISOMedia.Trim` (`lib/iso_media/trim.ex`) — `trim/3`: time-based lossless trim of all tracks (dts selection + snap-to-keyframe, table rebuild, interleave-preserving segment-list `mdat`, duration updates). Exposed as `ISOMedia.trim/3`.
```

And note in the `ISOMedia.SampleTable` bullet that it now also *encodes* tables (`build_stts/stsz/ctts/stss/stsc`) and that `%Sample{}` carries `duration`.

- [ ] **Step 5: Verify + commit**

Run: `mix test && mix compile --warnings-as-errors && mix format --check-formatted`
Expected: green, clean.

```bash
git add test/iso_media/trim_property_test.exs README.md CLAUDE.md
git commit -m "test: trim property suite; docs for trim"
```

---

## Self-Review Notes

- **Spec coverage:** `Sample.duration` + populate (T1); table encoders (T2); shared `MdatSource` + Extract refactor (T3); `MP4Builder` durations/sync + `mdhd` (T4); `Trim.trim/3` — dts selection + snap-to-keyframe + per-track table rebuild + interleave-preserving global run sort + up-front co64/header + duration updates (T5); keyframe-snap + real `sample_av.mp4` + lazy==eager (T6); property suite + docs (T7). Out-of-scope (`elst`, concat, re-chunk optimization, `stz2`/fragmented/HEIF) excluded.
- **Type consistency:** `%Sample{..., duration}` (T1) used by `Trim` (T5); `SampleTable.build_stts/stsz/ctts/stss/stsc` (T2) called by `Trim` (T5); `MdatSource.segment/3` (T3) used by `Extract` (T3) and `Trim` (T5); `ChunkOffset`/`MovieHeader`/`TrackHeader`/`MediaHeader` reused with their existing `decode`/`encode`.
- **Interleave:** kept chunk-runs sorted by original offset before offset assignment and `mdat` write; per-track `stco` filtered from the placed runs in track order.
- **Offset math:** co64/header decided up front (conservative bound), moov sized with dummy offsets, then real offsets assigned — mirrors `extract_track`.
- **Placeholders:** none — every code/test step is complete. (T5 Step 5 note adds the required `mdhd` to `MP4Builder.trak` and is committed with T5.)
