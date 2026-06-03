# Fragmented MP4 (fMP4) Indexing & Defragmentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Index fragmented MP4 (`moof`/`traf`/`trun`) into the same eager `[%ISOMedia.Sample{}]` as progressive files, and `ISOMedia.defragment/1` a fragmented tree into a standard progressive `[ftyp, moov, mdat]` — a pure metadata repack, memory-safe via the Phase 8 segment-list `mdat`.

**Architecture:** Four decode-only typed views (`trex`/`tfhd`/`tfdt`/`trun`) feed a cascade solver in `ISOMedia.FragmentIndex`, which runs one tree-local `Layout` walk to stamp each `moof`'s offset and emits per-track `[%Sample{}]` (offsets = `moof_offset + trun.data_offset`, `chunk_index` per `trun`). `ISOMedia.samples/2` dispatches to it when the tree is fragmented. `ISOMedia.defragment/1` reuses the existing progressive table encoders via a shared `ISOMedia.ProgressiveBuild` (extracted from `Concat`) plus `MdatSource.segment/3` to assemble the output.

**Tech Stack:** Elixir, ExUnit, binary pattern matching, `Bitwise`. Test fixture generated with `ffmpeg`. No new deps.

---

## File structure

**Created:**
- `lib/iso_media/boxes/track_extends.ex` — `trex` decoder
- `lib/iso_media/boxes/track_fragment_header.ex` — `tfhd` decoder
- `lib/iso_media/boxes/track_fragment_decode_time.ex` — `tfdt` decoder
- `lib/iso_media/boxes/track_run.ex` — `trun` decoder
- `lib/iso_media/fragment_index.ex` — `fragmented?/1`, cascade solver, `samples/2`
- `lib/iso_media/progressive_build.ex` — shared progressive assembler (extracted from `Concat`)
- `lib/iso_media/defragment.ex` — `defragment/1`

**Modified:**
- `lib/iso_media.ex` — `samples/2` dispatch; `defragment/1` delegator
- `lib/iso_media/concat.ex` — delegate assembly to `ProgressiveBuild`

**Tests created:**
- `test/iso_media/boxes/fragment_boxes_test.exs` — the four decoders
- `test/iso_media/fragment_index_test.exs` — cascade, offsets, real fixture, raises
- `test/iso_media/defragment_test.exs` — structural + headline equivalence
- Fixture: `test/fixtures/sample_frag.mp4`

**Note on `Bitwise`:** modules using `&&&` (`TrackFragmentHeader`, `TrackRun`, `FragmentIndex`) must `import Bitwise`.

---

## Task 1: fMP4 box decoders (trex, tfhd, tfdt, trun)

**Files:**
- Create: `lib/iso_media/boxes/track_extends.ex`, `track_fragment_header.ex`, `track_fragment_decode_time.ex`, `track_run.ex`
- Test: `test/iso_media/boxes/fragment_boxes_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/boxes/fragment_boxes_test.exs`:

```elixir
defmodule ISOMedia.Boxes.FragmentBoxesTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.{TrackExtends, TrackFragmentDecodeTime, TrackFragmentHeader, TrackRun}

  test "trex decodes the five default fields" do
    data = <<0, 0, 0, 0, 1::32, 1::32, 3000::32, 1024::32, 0x01010000::32>>
    t = TrackExtends.decode(%Box{type: "trex", data: data})
    assert t.track_id == 1
    assert t.default_sample_description_index == 1
    assert t.default_sample_duration == 3000
    assert t.default_sample_size == 1024
    assert t.default_sample_flags == 0x01010000
  end

  test "tfdt v0 and v1 decode base_media_decode_time" do
    v0 = TrackFragmentDecodeTime.decode(%Box{type: "tfdt", data: <<0, 0, 0, 0, 5120::32>>})
    assert v0.version == 0 and v0.base_media_decode_time == 5120
    v1 = TrackFragmentDecodeTime.decode(%Box{type: "tfdt", data: <<1, 0, 0, 0, 9_000_000_000::64>>})
    assert v1.version == 1 and v1.base_media_decode_time == 9_000_000_000
  end

  test "tfhd parses only the flag-gated fields and default_base_is_moof" do
    # flags 0x020008: default-base-is-moof + default-sample-duration-present
    data = <<0, 0x02, 0x00, 0x08, 7::32, 3000::32>>
    h = TrackFragmentHeader.decode(%Box{type: "tfhd", data: data})
    assert h.track_id == 7
    assert h.default_base_is_moof? == true
    assert h.default_sample_duration == 3000
    assert h.default_sample_size == nil
    assert h.base_data_offset == nil
  end

  test "trun parses data_offset, first_sample_flags and per-sample fields" do
    # flags 0x000F01: data-offset + first-sample-flags? no -> use 0x000301 = data-offset + duration + size
    # 0x000301 = data-offset-present(0x1) | sample-duration(0x100) | sample-size(0x200)
    data = <<0, 0x00, 0x03, 0x01, 2::32, 158::signed-32, 100::32, 500::32, 90::32, 480::32>>
    t = TrackRun.decode(%Box{type: "trun", data: data})
    assert t.sample_count == 2
    assert t.data_offset == 158
    assert t.first_sample_flags == nil
    assert t.samples == [
             %{duration: 100, size: 500, flags: nil, composition_offset: nil},
             %{duration: 90, size: 480, flags: nil, composition_offset: nil}
           ]
  end

  test "trun v1 composition offsets are signed" do
    # flags 0x000800 = sample-composition-time-offsets-present, version 1
    data = <<1, 0x00, 0x08, 0x00, 1::32, -50::signed-32>>
    t = TrackRun.decode(%Box{type: "trun", data: data})
    assert t.samples == [%{duration: nil, size: nil, flags: nil, composition_offset: -50}]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/boxes/fragment_boxes_test.exs`
Expected: FAIL — the four modules don't exist.

- [ ] **Step 3: Write the four decoders**

Create `lib/iso_media/boxes/track_extends.ex`:

```elixir
defmodule ISOMedia.Boxes.TrackExtends do
  @moduledoc "Typed view of the `trex` Track Extends box (inside `moov` → `mvex`)."
  alias ISOMedia.{Box, FullBox}

  defstruct [
    :track_id,
    :default_sample_description_index,
    :default_sample_duration,
    :default_sample_size,
    :default_sample_flags
  ]

  @doc "Decode a `trex` box."
  def decode(%Box{type: "trex", data: data}) do
    {_v, _f, <<track_id::32, dsdi::32, dur::32, size::32, flags::32>>} = FullBox.parse(data)

    %__MODULE__{
      track_id: track_id,
      default_sample_description_index: dsdi,
      default_sample_duration: dur,
      default_sample_size: size,
      default_sample_flags: flags
    }
  end
end
```

Create `lib/iso_media/boxes/track_fragment_decode_time.ex`:

```elixir
defmodule ISOMedia.Boxes.TrackFragmentDecodeTime do
  @moduledoc "Typed view of the `tfdt` Track Fragment Decode Time box."
  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :base_media_decode_time]

  @doc "Decode a `tfdt` box (v0 32-bit / v1 64-bit base time)."
  def decode(%Box{type: "tfdt", data: data}) do
    {version, _flags, rest} = FullBox.parse(data)
    %__MODULE__{version: version, base_media_decode_time: decode_time(version, rest)}
  end

  defp decode_time(0, <<t::32, _::binary>>), do: t
  defp decode_time(1, <<t::64, _::binary>>), do: t
end
```

Create `lib/iso_media/boxes/track_fragment_header.ex`:

```elixir
defmodule ISOMedia.Boxes.TrackFragmentHeader do
  @moduledoc "Typed view of the `tfhd` Track Fragment Header box."
  import Bitwise
  alias ISOMedia.{Box, FullBox}

  defstruct [
    :track_id,
    :base_data_offset,
    :sample_description_index,
    :default_sample_duration,
    :default_sample_size,
    :default_sample_flags,
    :default_base_is_moof?
  ]

  @base_data_offset 0x000001
  @sample_desc_index 0x000002
  @default_duration 0x000008
  @default_size 0x000010
  @default_flags 0x000020
  @default_base_is_moof 0x020000

  @doc "Decode a `tfhd` box (only flag-present optional fields are read)."
  def decode(%Box{type: "tfhd", data: data}) do
    {_v, <<flags::24>>, <<track_id::32, rest::binary>>} = FullBox.parse(data)
    {bdo, rest} = take(rest, flags, @base_data_offset, 64)
    {sdi, rest} = take(rest, flags, @sample_desc_index, 32)
    {dur, rest} = take(rest, flags, @default_duration, 32)
    {size, rest} = take(rest, flags, @default_size, 32)
    {dflags, _rest} = take(rest, flags, @default_flags, 32)

    %__MODULE__{
      track_id: track_id,
      base_data_offset: bdo,
      sample_description_index: sdi,
      default_sample_duration: dur,
      default_sample_size: size,
      default_sample_flags: dflags,
      default_base_is_moof?: (flags &&& @default_base_is_moof) != 0
    }
  end

  defp take(bin, flags, mask, bits) do
    if (flags &&& mask) != 0 do
      <<v::size(bits), rest::binary>> = bin
      {v, rest}
    else
      {nil, bin}
    end
  end
end
```

Create `lib/iso_media/boxes/track_run.ex`:

```elixir
defmodule ISOMedia.Boxes.TrackRun do
  @moduledoc "Typed view of the `trun` Track Run box (per-sample list)."
  import Bitwise
  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :sample_count, :data_offset, :first_sample_flags, :samples]

  @data_offset 0x000001
  @first_sample_flags 0x000004
  @sample_duration 0x000100
  @sample_size 0x000200
  @sample_flags 0x000400
  @sample_comp_offset 0x000800

  @doc "Decode a `trun` box."
  def decode(%Box{type: "trun", data: data}) do
    {version, <<flags::24>>, <<sample_count::32, rest::binary>>} = FullBox.parse(data)
    {data_offset, rest} = take(rest, flags, @data_offset, :signed)
    {first_sample_flags, rest} = take(rest, flags, @first_sample_flags, :unsigned)
    samples = decode_samples(rest, sample_count, version, flags, [])

    %__MODULE__{
      version: version,
      sample_count: sample_count,
      data_offset: data_offset,
      first_sample_flags: first_sample_flags,
      samples: samples
    }
  end

  defp decode_samples(_bin, 0, _v, _flags, acc), do: Enum.reverse(acc)

  defp decode_samples(bin, n, version, flags, acc) do
    {duration, bin} = take(bin, flags, @sample_duration, :unsigned)
    {size, bin} = take(bin, flags, @sample_size, :unsigned)
    {sflags, bin} = take(bin, flags, @sample_flags, :unsigned)
    {coff, bin} = take_comp(bin, flags, version)
    sample = %{duration: duration, size: size, flags: sflags, composition_offset: coff}
    decode_samples(bin, n - 1, version, flags, [sample | acc])
  end

  defp take(bin, flags, mask, :unsigned) do
    if (flags &&& mask) != 0 do
      <<v::32, rest::binary>> = bin
      {v, rest}
    else
      {nil, bin}
    end
  end

  defp take(bin, flags, mask, :signed) do
    if (flags &&& mask) != 0 do
      <<v::signed-32, rest::binary>> = bin
      {v, rest}
    else
      {nil, bin}
    end
  end

  defp take_comp(bin, flags, version) do
    cond do
      (flags &&& @sample_comp_offset) == 0 -> {nil, bin}
      version == 1 -> (fn <<v::signed-32, r::binary>> -> {v, r} end).(bin)
      true -> (fn <<v::32, r::binary>> -> {v, r} end).(bin)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/boxes/fragment_boxes_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/boxes/track_extends.ex lib/iso_media/boxes/track_fragment_header.ex lib/iso_media/boxes/track_fragment_decode_time.ex lib/iso_media/boxes/track_run.ex test/iso_media/boxes/fragment_boxes_test.exs
git commit -m "feat: decode-only typed views for trex/tfhd/tfdt/trun"
```

---

## Task 2: `FragmentIndex.fragmented?/1` and `samples/2` dispatch

**Files:**
- Create: `lib/iso_media/fragment_index.ex`
- Modify: `lib/iso_media.ex:22-27`
- Test: `test/iso_media/fragment_index_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/fragment_index_test.exs`:

```elixir
defmodule ISOMedia.FragmentIndexTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FragmentIndex}

  defp moov(children), do: %Box{type: "moov", children: children}
  defp leaf(type, data), do: %Box{type: type, data: data}

  test "fragmented?/1 is true only with both mvex and moof" do
    mvex = %Box{type: "mvex", children: [leaf("trex", <<0::32, 1::32, 1::32, 0::32, 0::32, 0::32>>)]}
    moof = %Box{type: "moof", children: []}

    assert FragmentIndex.fragmented?([moov([mvex]), moof]) == true
    assert FragmentIndex.fragmented?([moov([mvex])]) == false
    assert FragmentIndex.fragmented?([moov([]), moof]) == false
    assert FragmentIndex.fragmented?([moov([])]) == false
  end

  test "samples/2 still routes a progressive file to SampleTable" do
    {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
    [tid | _] = ISOMedia.track_ids(boxes)
    assert is_list(ISOMedia.samples(boxes, tid))
    assert FragmentIndex.fragmented?(boxes) == false
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/fragment_index_test.exs`
Expected: FAIL — `FragmentIndex` does not exist.

- [ ] **Step 3: Write `FragmentIndex` (predicate + stub) and wire dispatch**

Create `lib/iso_media/fragment_index.ex` (no `Bitwise`/`Box` yet — Task 3 adds them with their first use, keeping this commit warning-clean):

```elixir
defmodule ISOMedia.FragmentIndex do
  @moduledoc """
  Indexes fragmented MP4 (`moof`/`traf`/`trun`) into the same `[%ISOMedia.Sample{}]`
  the progressive indexer produces. Offsets are resolved tree-locally (a single
  `Layout` walk stamps each `moof`'s position), and the cascade `trun → tfhd → trex`
  resolves per-sample duration/size/flags. `chunk_index` is a per-`trun` counter.
  """

  @doc "True when the tree is fragmented: has a `moov`/`mvex` and at least one `moof`."
  def fragmented?(boxes) when is_list(boxes) do
    moov = Enum.find(boxes, &(&1.type == "moov"))
    has_mvex = moov != nil and Enum.any?(moov.children, &(&1.type == "mvex"))
    has_moof = Enum.any?(boxes, &(&1.type == "moof"))
    has_mvex and has_moof
  end

  @doc "Index the fragmented track `track_id` into `[%ISOMedia.Sample{}]`."
  def samples(_boxes, _track_id) do
    raise ArgumentError, "FragmentIndex.samples/2 not yet implemented"
  end
end
```

In `lib/iso_media.ex`, replace `samples/2` (lines 22-27):

```elixir
  @doc "Decode a track's sample tables into `[%ISOMedia.Sample{}]` (progressive or fragmented)."
  def samples(boxes, track_id) do
    if ISOMedia.FragmentIndex.fragmented?(boxes) do
      ISOMedia.FragmentIndex.samples(boxes, track_id)
    else
      case ISOMedia.Extract.find_trak(boxes, track_id) do
        nil -> raise ArgumentError, "no track with track_id #{track_id}"
        trak -> ISOMedia.SampleTable.build(trak)
      end
    end
  end
```

- [ ] **Step 4: Run test + warnings check**

Run: `mix test test/iso_media/fragment_index_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings. If `alias ISOMedia.Box` warns as unused, remove that line and re-run.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/fragment_index.ex lib/iso_media.ex test/iso_media/fragment_index_test.exs
git commit -m "feat: FragmentIndex.fragmented?/1 and samples/2 dispatch"
```

---

## Task 3: The cascade solver (`resolve_run/2`)

**Files:**
- Modify: `lib/iso_media/fragment_index.ex`
- Test: `test/iso_media/fragment_index_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/iso_media/fragment_index_test.exs` (inside the module):

```elixir
  alias ISOMedia.Boxes.TrackRun

  describe "resolve_run/2 cascade" do
    test "uses trun entry values when present" do
      trun = %TrackRun{
        version: 0,
        sample_count: 1,
        data_offset: 0,
        first_sample_flags: nil,
        samples: [%{duration: 50, size: 10, flags: 0x00000000, composition_offset: 7}]
      }

      assert FragmentIndex.resolve_run(trun, %{duration: 999, size: 999, flags: 0x00010000}) ==
               [%{duration: 50, size: 10, composition_offset: 7, sync?: true}]
    end

    test "falls back to defaults (tfhd-over-trex merged) when trun omits fields" do
      trun = %TrackRun{
        version: 0,
        sample_count: 1,
        data_offset: 0,
        first_sample_flags: nil,
        samples: [%{duration: nil, size: nil, flags: nil, composition_offset: nil}]
      }

      # default flags mark non-sync (bit 0x00010000 set) -> sync? false
      assert FragmentIndex.resolve_run(trun, %{duration: 3000, size: 1024, flags: 0x00010000}) ==
               [%{duration: 3000, size: 1024, composition_offset: 0, sync?: false}]
    end

    test "first_sample_flags applies to sample 1 only" do
      trun = %TrackRun{
        version: 0,
        sample_count: 2,
        data_offset: 0,
        first_sample_flags: 0x02000000,
        samples: [
          %{duration: 30, size: 5, flags: nil, composition_offset: nil},
          %{duration: 30, size: 5, flags: 0x00010000, composition_offset: nil}
        ]
      }

      assert [%{sync?: true}, %{sync?: false}] =
               FragmentIndex.resolve_run(trun, %{duration: nil, size: nil, flags: 0x00010000})
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/fragment_index_test.exs`
Expected: FAIL — `resolve_run/2` undefined.

- [ ] **Step 3: Implement the cascade**

In `lib/iso_media/fragment_index.ex`, add `import Bitwise` to the module head (if not present), and add:

```elixir
  alias ISOMedia.Boxes.TrackRun

  @non_sync 0x00010000

  @doc """
  Resolve one `trun`'s per-sample fields against merged `defaults`
  (`%{duration, size, flags}`, already tfhd-over-trex). Returns
  `[%{duration, size, composition_offset, sync?}]`. `sync?` negates the
  `sample_is_non_sync_sample` bit.
  """
  def resolve_run(%TrackRun{} = trun, defaults) do
    trun.samples
    |> Enum.with_index()
    |> Enum.map(fn {s, i} ->
      flags = s.flags || first_flags(trun, i) || defaults.flags || 0

      %{
        duration: s.duration || defaults.duration || 0,
        size: s.size || defaults.size || 0,
        composition_offset: s.composition_offset || 0,
        sync?: (flags &&& @non_sync) == 0
      }
    end)
  end

  defp first_flags(%TrackRun{first_sample_flags: f}, 0), do: f
  defp first_flags(_trun, _i), do: nil
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/fragment_index_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/fragment_index.ex test/iso_media/fragment_index_test.exs
git commit -m "feat: FragmentIndex cascade solver (trun -> tfhd -> trex, sync flag)"
```

---

## Task 4: Tree-local offsets, dts/pts, chunk_index, full `samples/2`

**Files:**
- Modify: `lib/iso_media/fragment_index.ex`
- Test: `test/iso_media/fragment_index_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/iso_media/fragment_index_test.exs`:

```elixir
  describe "samples/2 assembly" do
    # Build a minimal single-track fragmented tree by hand.
    defp full_box(type, version, flags_int, payload) do
      %Box{type: type, data: <<version::8, flags_int::24, payload::binary>>}
    end

    defp tiny_frag_tree do
      trex = full_box("trex", 0, 0, <<1::32, 1::32, 0::32, 0::32, 0::32>>)
      mvex = %Box{type: "mvex", children: [trex]}
      # progressive-looking trak skeleton is unnecessary for indexing; moov just needs mvex
      moov = %Box{type: "moov", children: [mvex]}

      # one moof: tfhd(track 1, default-base-is-moof + default duration 100 + size 10),
      # tfdt base 0, trun(2 samples, data_offset points at sibling mdat payload)
      tfhd = full_box("tfhd", 0, 0x020018, <<1::32, 100::32, 10::32>>)
      tfdt = full_box("tfdt", 0, 0, <<0::32>>)
      # trun flags 0x000001 (data-offset only); 2 samples inherit defaults
      # moof size: 8(moof) + traf... we compute data_offset so sample_start lands in mdat payload.
      traf = %Box{type: "traf", children: [tfhd, tfdt, full_box("trun", 0, 0x000001, <<2::32, 0::signed-32>>)]}
      moof = %Box{type: "moof", children: [traf]}
      ftyp = %Box{type: "ftyp", data: <<"isom", 0::32>>}
      # mdat holds 20 bytes (2 samples x 10)
      mdat = %Box{type: "mdat", data: <<0::160>>}

      # Set trun data_offset so first sample lands at mdat payload start:
      # sample_start = moof_offset + data_offset must equal mdat payload_start.
      tree0 = [ftyp, moov, moof, mdat]
      moof_off = box_offset(tree0, moof)
      mdat_payload = box_offset(tree0, mdat) + 8
      data_offset = mdat_payload - moof_off
      trun = full_box("trun", 0, 0x000001, <<2::32, data_offset::signed-32>>)
      traf2 = %Box{type: "traf", children: [tfhd, tfdt, trun]}
      moof2 = %Box{type: "moof", children: [traf2]}
      [ftyp, moov, moof2, mdat]
    end

    defp box_offset(boxes, target) do
      {_, off} =
        Enum.reduce_while(boxes, {0, nil}, fn b, {acc, _} ->
          if b == target, do: {:halt, {acc, acc}}, else: {:cont, {acc + ISOMedia.Layout.box_size(b), nil}}
        end)

      off
    end

    test "computes offsets, dts/pts, sizes, and per-trun chunk_index" do
      samples = FragmentIndex.samples(tiny_frag_tree(), 1)
      assert length(samples) == 2
      [s1, s2] = samples
      assert s1.index == 1 and s2.index == 2
      assert s1.chunk_index == 1 and s2.chunk_index == 1
      assert s1.size == 10 and s2.size == 10
      assert s1.duration == 100
      assert s1.dts == 0 and s2.dts == 100
      assert s1.pts == 0 and s2.pts == 100
      # offsets resolve into the mdat payload, contiguous
      assert s2.offset == s1.offset + 10
    end

    test "raises when a fragment does not use default-base-is-moof" do
      # tfhd without 0x020000
      tfhd = full_box("tfhd", 0, 0x000008, <<1::32, 100::32>>)
      traf = %Box{type: "traf", children: [tfhd, full_box("trun", 0, 0x000001, <<1::32, 0::signed-32>>)]}
      moof = %Box{type: "moof", children: [traf]}
      trex = full_box("trex", 0, 0, <<1::32, 1::32, 0::32, 0::32, 0::32>>)
      moov = %Box{type: "moov", children: [%Box{type: "mvex", children: [trex]}]}
      tree = [%Box{type: "ftyp", data: <<0::32>>}, moov, moof, %Box{type: "mdat", data: <<0::80>>}]

      assert_raise ArgumentError, ~r/default-base-is-moof/, fn -> FragmentIndex.samples(tree, 1) end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/fragment_index_test.exs`
Expected: FAIL — `samples/2` still the stub raise.

- [ ] **Step 3: Implement the assembly**

In `lib/iso_media/fragment_index.ex`, add aliases and replace the stub `samples/2`:

```elixir
  alias ISOMedia.{Layout, Sample}
  alias ISOMedia.Boxes.{TrackExtends, TrackFragmentDecodeTime, TrackFragmentHeader}

  def samples(boxes, track_id) do
    trex = trex_for!(boxes, track_id)

    {rev, _sidx, _cidx} =
      boxes
      |> moof_layout()
      |> Enum.reduce({[], 0, 0}, fn %{moof: moof, offset: moof_off}, acc ->
        case traf_for(moof, track_id) do
          nil -> acc
          traf -> index_traf(traf, moof_off, trex, acc)
        end
      end)

    Enum.reverse(rev)
  end

  # One %{moof, offset} per moof, offset stamped by the tree-local Layout walk.
  defp moof_layout(boxes) do
    {recs, _end} =
      Enum.flat_map_reduce(boxes, 0, fn box, off ->
        rec = if box.type == "moof", do: [%{moof: box, offset: off}], else: []
        {rec, off + Layout.box_size(box)}
      end)

    recs
  end

  defp index_traf(traf, moof_off, trex, {acc, sidx, cidx}) do
    tfhd = TrackFragmentHeader.decode(child!(traf, "tfhd"))

    unless tfhd.default_base_is_moof? do
      raise ArgumentError,
            "fMP4: track #{tfhd.track_id} fragment does not set default-base-is-moof " <>
              "(unsupported addressing)"
    end

    check_unencrypted!(traf)

    base_dts =
      case child(traf, "tfdt") do
        nil -> 0
        box -> TrackFragmentDecodeTime.decode(box).base_media_decode_time
      end

    defaults = defaults(tfhd, trex)
    truns = Enum.filter(traf.children, &(&1.type == "trun"))

    {acc, sidx, cidx, _dts} =
      Enum.reduce(truns, {acc, sidx, cidx, base_dts}, fn trun_box, {acc, si, ci, dts} ->
        trun = ISOMedia.Boxes.TrackRun.decode(trun_box)
        ci = ci + 1
        run_start = moof_off + (trun.data_offset || 0)

        {acc, si, _off, dts} =
          trun
          |> resolve_run(defaults)
          |> Enum.reduce({acc, si, run_start, dts}, fn r, {acc, si, off, dts} ->
            si = si + 1

            sample = %Sample{
              index: si,
              chunk_index: ci,
              dts: dts,
              duration: r.duration,
              pts: dts + r.composition_offset,
              size: r.size,
              offset: off,
              sync?: r.sync?
            }

            {[sample | acc], si, off + r.size, dts + r.duration}
          end)

        {acc, si, ci, dts}
      end)

    {acc, sidx, cidx}
  end

  defp defaults(tfhd, trex) do
    %{
      duration: tfhd.default_sample_duration || trex.default_sample_duration,
      size: tfhd.default_sample_size || trex.default_sample_size,
      flags: tfhd.default_sample_flags || trex.default_sample_flags
    }
  end

  defp trex_for!(boxes, track_id) do
    moov = Enum.find(boxes, &(&1.type == "moov")) || raise ArgumentError, "fMP4: no moov"
    mvex = Enum.find(moov.children, &(&1.type == "mvex")) || raise ArgumentError, "fMP4: no mvex"

    box =
      Enum.find(mvex.children, fn b ->
        b.type == "trex" and TrackExtends.decode(b).track_id == track_id
      end)

    if box, do: TrackExtends.decode(box), else: raise(ArgumentError, "fMP4: no trex for track #{track_id}")
  end

  defp traf_for(moof, track_id) do
    Enum.find(moof.children, fn b ->
      b.type == "traf" and
        case child(b, "tfhd") do
          nil -> false
          tfhd -> TrackFragmentHeader.decode(tfhd).track_id == track_id
        end
    end)
  end

  defp check_unencrypted!(traf) do
    if Enum.any?(traf.children, &(&1.type in ~w(senc saiz saio))) do
      raise ArgumentError, "fMP4: encrypted fragments (senc/saiz/saio) are not supported"
    end
  end

  defp child(%Box{children: children}, type), do: Enum.find(children, &(&1.type == type))
  defp child!(box, type), do: child(box, type) || raise(ArgumentError, "fMP4: traf missing #{type}")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/fragment_index_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/fragment_index.ex test/iso_media/fragment_index_test.exs
git commit -m "feat: FragmentIndex tree-local offsets, dts/pts, per-trun chunk_index"
```

---

## Task 5: Real fragmented fixture + integration

**Files:**
- Add fixture: `test/fixtures/sample_frag.mp4`
- Modify: `test/fixtures/README.md`
- Test: `test/iso_media/fragment_index_test.exs`

- [ ] **Step 1: Generate the fixture**

Run (requires `ffmpeg` on PATH):

```bash
cd test/fixtures && ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 \
  -f lavfi -i sine=frequency=440:duration=1 \
  -pix_fmt yuv420p -c:a aac -shortest \
  -movflags frag_keyframe+empty_moov+default_base_moof sample_frag.mp4
```

Then append to `test/fixtures/README.md`:

```markdown

    # Fragmented (fMP4) fixture for Phase 9 indexing/defragment:
    ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 \
      -f lavfi -i sine=frequency=440:duration=1 \
      -pix_fmt yuv420p -c:a aac -shortest \
      -movflags frag_keyframe+empty_moov+default_base_moof sample_frag.mp4
```

Verify it round-trips losslessly first (the Phase 1 invariant must hold for fMP4):

```bash
cd ../.. && mix run -e 'bin = File.read!("test/fixtures/sample_frag.mp4"); {:ok, b} = ISOMedia.parse(bin); ^bin = ISOMedia.serialize(b); IO.puts("round-trip OK")'
```

Expected: `round-trip OK` (if this fails, the parser/registry needs the fMP4 container types — they are already in Registry, so it should pass).

- [ ] **Step 2: Write the failing integration test**

Append to `test/iso_media/fragment_index_test.exs`:

```elixir
  describe "real fragmented fixture" do
    @frag "test/fixtures/sample_frag.mp4"

    test "indexes every track with monotonic dts and contiguous-per-run offsets" do
      {:ok, boxes} = ISOMedia.read(@frag)
      assert FragmentIndex.fragmented?(boxes)
      tids = ISOMedia.track_ids(boxes)
      assert length(tids) == 2

      for tid <- tids do
        samples = ISOMedia.samples(boxes, tid)
        assert length(samples) > 0
        dts = Enum.map(samples, & &1.dts)
        assert dts == Enum.sort(dts)
        assert Enum.all?(samples, &(&1.size > 0))
        assert Enum.map(samples, & &1.index) == Enum.to_list(1..length(samples))
      end
    end

    test "lazy and eager indexing are identical" do
      {:ok, eager} = ISOMedia.read(@frag)
      {:ok, lazy} = ISOMedia.read(@frag, lazy: true)
      [tid | _] = ISOMedia.track_ids(eager)
      assert ISOMedia.samples(eager, tid) == ISOMedia.samples(lazy, tid)
    end

    test "raises on an encrypted fragment" do
      {:ok, boxes} = ISOMedia.read(@frag)
      [tid | _] = ISOMedia.track_ids(boxes)
      # inject a senc into the first matching traf
      boxes2 =
        Enum.map(boxes, fn
          %ISOMedia.Box{type: "moof"} = m ->
            traf = hd(Enum.filter(m.children, &(&1.type == "traf")))
            poisoned = %{traf | children: traf.children ++ [%ISOMedia.Box{type: "senc", data: <<>>}]}
            %{m | children: [poisoned | tl(m.children)]}

          other ->
            other
        end)

      assert_raise ArgumentError, ~r/encrypted/, fn -> ISOMedia.samples(boxes2, tid) end
    end
  end
```

- [ ] **Step 3: Run test to verify it passes (or surfaces a real bug)**

Run: `mix test test/iso_media/fragment_index_test.exs`
Expected: PASS. If the dts/offset assertions fail on the real file, that is a genuine cascade/offset bug — debug with `superpowers:systematic-debugging` before proceeding, do not weaken the assertions.

- [ ] **Step 4: Commit**

```bash
git add test/fixtures/sample_frag.mp4 test/fixtures/README.md test/iso_media/fragment_index_test.exs
git commit -m "test: real fMP4 fixture; index integration, lazy==eager, encrypted raise"
```

---

## Task 6: Extract `ProgressiveBuild` from `Concat`

**Files:**
- Create: `lib/iso_media/progressive_build.ex`
- Modify: `lib/iso_media/concat.ex`
- Test: existing concat suites (the regression gate)

- [ ] **Step 1: Confirm concat baseline is green**

Run: `mix test test/iso_media/concat_test.exs test/iso_media/concat_av_test.exs test/iso_media/concat_property_test.exs`
Expected: PASS.

- [ ] **Step 2: Create `ProgressiveBuild` with concat's assembly body**

Create `lib/iso_media/progressive_build.ex` by moving concat.ex's assembly internals verbatim — the body from `concat.ex:34` (`inputs_data`/`tagged`/`placed`/`co_kind`/`moov_final`/`segments`/`mdat`) plus every private helper from `assemble_moov/6` through `insert_traks/2` (concat.ex:153-296). The public entry:

```elixir
defmodule ISOMedia.ProgressiveBuild do
  @moduledoc """
  Assemble a progressive `[ftyp, moov, mdat]` tree from one or more inputs' per-track
  samples + `mdat` sources. Shared by `Concat` (N inputs) and `Defragment` (one input).
  Preserves interleave (runs sorted by original offset for the byte layout) while keeping
  logical `{input, chunk}` order for each track's `stco`.
  """
  alias ISOMedia.{Box, BoxPath, Layout, MdatSource, SampleTable}
  alias ISOMedia.Boxes.{ChunkOffset, MediaHeader, MovieHeader, TrackHeader}

  @uint32_max 0xFFFFFFFF

  @doc """
  `inputs_data` is a list of `%{samples: [[%Sample{}] per track], mdats: collect/1 records}`.
  `base_moov` supplies the trak skeletons and non-trak children (its `trak`s' `stbl` is
  fully replaced; any `mvex` must already be stripped by the caller). Returns `[ftyp, moov, mdat]`.
  """
  def assemble(ftyp, base_moov, inputs_data, movie_ts) do
    track_count = length(traks(base_moov))

    tagged =
      inputs_data
      |> Enum.with_index()
      |> Enum.flat_map(fn {d, input_i} ->
        d.samples
        |> Enum.with_index()
        |> Enum.flat_map(fn {samples, ti} ->
          samples
          |> Enum.chunk_by(& &1.chunk_index)
          |> Enum.with_index()
          |> Enum.map(fn {run, chunk_i} ->
            %{
              input_i: input_i,
              track_i: ti,
              chunk_i: chunk_i,
              mdats: d.mdats,
              offset: hd(run).offset,
              length: Enum.sum(Enum.map(run, & &1.size))
            }
          end)
        end)
        |> Enum.sort_by(& &1.offset)
      end)

    total = Enum.sum(Enum.map(tagged, & &1.length))
    {mdat_mode, mdat_header} = if 8 + total > @uint32_max, do: {:large, 16}, else: {:compact, 8}

    runs_per_track =
      Map.new(0..(track_count - 1)//1, fn ti -> {ti, Enum.count(tagged, &(&1.track_i == ti))} end)

    dummy = fn -> Map.new(runs_per_track, fn {ti, n} -> {ti, List.duplicate(0, n)} end) end

    bound =
      Layout.box_size(ftyp) +
        Layout.box_size(assemble_moov(base_moov, inputs_data, track_count, dummy.(), :co64, movie_ts)) +
        16 + total

    co_kind = if bound > @uint32_max, do: :co64, else: :stco

    moov0 = assemble_moov(base_moov, inputs_data, track_count, dummy.(), co_kind, movie_ts)
    mdat_payload_start = Layout.box_size(ftyp) + Layout.box_size(moov0) + mdat_header

    {placed, _} =
      Enum.map_reduce(tagged, mdat_payload_start, fn run, pos ->
        {Map.put(run, :new_offset, pos), pos + run.length}
      end)

    offsets_by_track =
      Map.new(0..(track_count - 1)//1, fn ti ->
        offs =
          placed
          |> Enum.filter(&(&1.track_i == ti))
          |> Enum.sort_by(&{&1.input_i, &1.chunk_i})
          |> Enum.map(& &1.new_offset)

        {ti, offs}
      end)

    moov_final = assemble_moov(base_moov, inputs_data, track_count, offsets_by_track, co_kind, movie_ts)
    segments = Enum.map(placed, fn run -> MdatSource.segment(run.mdats, run.offset, run.length) end)
    mdat = %Box{type: "mdat", data: segments, size_mode: mdat_mode}

    [ftyp, moov_final, mdat]
  end

  # ... move assemble_moov/6, build_joined_trak/7, sync_positions/1, traks/1,
  # track_timescale/1, scale/3, opt/1, drop_edts/1, put_stbl/2, set_mdhd_duration/2,
  # set_tkhd_duration/2, set_mvhd_duration/2, insert_traks/2 here VERBATIM from concat.ex.
end
```

Move helpers `assemble_moov/6` (rename its first param `first_moov` → `base_moov`), `build_joined_trak/7`, `sync_positions/1`, `traks/1`, `track_timescale/1`, `scale/3`, `opt/1`, `drop_edts/1`, `put_stbl/2`, `set_mdhd_duration/2`, `set_tkhd_duration/2`, `set_mvhd_duration/2`, `insert_traks/2` from `concat.ex` into `ProgressiveBuild` unchanged.

- [ ] **Step 3: Rewrite `Concat` to delegate**

Replace `concat.ex`'s `concat([first | _] = inputs)` clause body (lines 22-117) so it builds `inputs_data` and delegates; keep `check_compatibility!/1` and its helpers (`moov_of`, `traks`, `stsd_data`, `track_timescale`, `movie_timescale`) in `Concat`:

```elixir
  def concat([first | _] = inputs) do
    check_compatibility!(inputs)

    ftyp = Enum.find(first, &(&1.type == "ftyp")) || raise ArgumentError, "first input has no ftyp"
    first_moov = Enum.find(first, &(&1.type == "moov")) || raise ArgumentError, "first input has no moov"
    movie_ts = movie_timescale(first_moov)

    inputs_data =
      Enum.map(inputs, fn boxes ->
        moov = Enum.find(boxes, &(&1.type == "moov"))
        tks = Enum.filter(moov.children, &(&1.type == "trak"))
        %{samples: Enum.map(tks, &SampleTable.build/1), mdats: MdatSource.collect(boxes)}
      end)

    ISOMedia.ProgressiveBuild.assemble(ftyp, first_moov, inputs_data, movie_ts)
  end
```

Then delete from `concat.ex` the now-moved helpers (everything under `# --- moov / trak rebuild ---` through `insert_traks/2`), keeping only `concat/1`, `check_compatibility!/1`, `moov_of/1`, `traks/1`, `stsd_data/1`, `track_timescale/1`, `movie_timescale/1`. Remove now-unused aliases (`ChunkOffset`, `MediaHeader`, `MovieHeader`, `TrackHeader`, `Layout`, `BoxPath`) from `Concat` if the warnings check flags them; keep `Box`, `MdatSource`, `SampleTable`.

- [ ] **Step 4: Run the concat suite + warnings (the regression gate)**

Run: `mix test test/iso_media/concat_test.exs test/iso_media/concat_av_test.exs test/iso_media/concat_property_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings. Concat's behavior is unchanged — only its assembly moved.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/progressive_build.ex lib/iso_media/concat.ex
git commit -m "refactor: extract ISOMedia.ProgressiveBuild (shared by Concat, Defragment)"
```

---

## Task 7: `defragment/1` + headline equivalence proof

**Files:**
- Create: `lib/iso_media/defragment.ex`
- Modify: `lib/iso_media.ex` (delegator), `CLAUDE.md`
- Test: `test/iso_media/defragment_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/defragment_test.exs`:

```elixir
defmodule ISOMedia.DefragmentTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FileSlice, FragmentIndex, MdatSource}

  @frag "test/fixtures/sample_frag.mp4"

  # Concatenate every sample's resolved bytes, in index order.
  defp sample_bytes(boxes, samples) do
    recs = MdatSource.collect(boxes)

    samples
    |> Enum.map(fn s ->
      seg = MdatSource.segment(recs, s.offset, s.size)
      ISOMedia.Box.read_data(%Box{type: "free", data: List.wrap(seg)})
    end)
    |> IO.iodata_to_binary()
  end

  test "output is a progressive [ftyp, moov, mdat] with no moof/mvex" do
    {:ok, boxes} = ISOMedia.read(@frag)
    out = ISOMedia.defragment(boxes)
    assert Enum.map(out, & &1.type) == ["ftyp", "moov", "mdat"]
    moov = Enum.find(out, &(&1.type == "moov"))
    refute Enum.any?(moov.children, &(&1.type == "mvex"))
    refute Enum.any?(out, &(&1.type == "moof"))
    # defragmented output is itself a normal progressive file
    refute FragmentIndex.fragmented?(out)
  end

  test "defragment preserves every sample's metadata and bytes per track" do
    {:ok, boxes} = ISOMedia.read(@frag)
    out = ISOMedia.defragment(boxes)
    {:ok, reparsed} = ISOMedia.parse(ISOMedia.serialize(out))

    for tid <- ISOMedia.track_ids(boxes) do
      frag_samples = ISOMedia.samples(boxes, tid)
      prog_samples = ISOMedia.samples(reparsed, tid)

      # metadata equivalence (timeline + sizes + sync flags)
      assert Enum.map(prog_samples, & &1.dts) == Enum.map(frag_samples, & &1.dts)
      assert Enum.map(prog_samples, & &1.pts) == Enum.map(frag_samples, & &1.pts)
      assert Enum.map(prog_samples, & &1.size) == Enum.map(frag_samples, & &1.size)
      assert Enum.map(prog_samples, & &1.sync?) == Enum.map(frag_samples, & &1.sync?)

      # byte equivalence: the media itself is unchanged
      assert sample_bytes(reparsed, prog_samples) == sample_bytes(boxes, frag_samples)
    end
  end

  test "lazy and eager defragment produce identical bytes" do
    {:ok, eager} = ISOMedia.read(@frag)
    {:ok, lazy} = ISOMedia.read(@frag, lazy: true)
    assert ISOMedia.serialize(ISOMedia.defragment(eager)) ==
             ISOMedia.serialize(ISOMedia.defragment(lazy))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/defragment_test.exs`
Expected: FAIL — `ISOMedia.defragment/1` undefined.

- [ ] **Step 3: Implement `Defragment` and the delegator**

Create `lib/iso_media/defragment.ex`:

```elixir
defmodule ISOMedia.Defragment do
  @moduledoc """
  Repack a fragmented MP4 (`moof`/`traf`/`trun`) into a standard progressive
  `[ftyp, moov, mdat]` — a pure metadata edit, no transcoding. Samples come from
  `FragmentIndex`; the output is assembled by `ISOMedia.ProgressiveBuild`, so the
  `mdat` is a Phase 8 segment list referencing each fragment's bytes (memory-safe).
  """
  alias ISOMedia.{Box, BoxPath, FragmentIndex, MdatSource, ProgressiveBuild}
  alias ISOMedia.Boxes.{MovieHeader, TrackHeader}

  @doc "Defragment one parsed fragmented tree into a progressive tree."
  def defragment(boxes) do
    unless FragmentIndex.fragmented?(boxes) do
      raise ArgumentError, "defragment: not a fragmented file (needs moov/mvex + moof)"
    end

    ftyp = Enum.find(boxes, &(&1.type == "ftyp")) || raise ArgumentError, "defragment: no ftyp"
    moov = Enum.find(boxes, &(&1.type == "moov")) || raise ArgumentError, "defragment: no moov"

    base_traks = Enum.filter(moov.children, &(&1.type == "trak"))
    track_ids = Enum.map(base_traks, &track_id_of/1)
    per_track = Enum.map(track_ids, &FragmentIndex.samples(boxes, &1))

    movie_ts =
      case BoxPath.dig(moov, ["mvhd"]) do
        %Box{} = mvhd -> MovieHeader.decode(mvhd).timescale
        nil -> 1
      end

    base_moov = %{moov | children: Enum.reject(moov.children, &(&1.type == "mvex"))}
    inputs_data = [%{samples: per_track, mdats: MdatSource.collect(boxes)}]

    ProgressiveBuild.assemble(ftyp, base_moov, inputs_data, movie_ts)
  end

  defp track_id_of(trak) do
    TrackHeader.decode(BoxPath.dig(trak, ["tkhd"])).track_id
  end
end
```

In `lib/iso_media.ex`, add after `concat/1` (around line 36):

```elixir
  @doc "Defragment a fragmented MP4 tree into a progressive one. See `ISOMedia.Defragment.defragment/1`."
  def defragment(boxes), do: ISOMedia.Defragment.defragment(boxes)
```

Confirm `ISOMedia.Boxes.TrackHeader` exposes `track_id` (it decodes `tkhd`; `track_id` is a field of the `TrackHeader` struct). If the field name differs, use the actual field.

- [ ] **Step 4: Run test to verify it passes (or surfaces a real bug)**

Run: `mix test test/iso_media/defragment_test.exs`
Expected: PASS. A byte-equivalence failure is a genuine defragment/offset bug — debug with `superpowers:systematic-debugging`, do not weaken assertions.

- [ ] **Step 5: Update CLAUDE.md and commit**

Add to `CLAUDE.md`'s architecture list: a `FragmentIndex` bullet (fMP4 indexing + cascade + `fragmented?/1`), a `ProgressiveBuild` bullet (shared assembler), and a `Defragment` bullet (`defragment/1`), and note `ISOMedia.samples/2` now indexes fragmented tracks transparently and `ISOMedia.defragment/1` is exposed. Then:

```bash
git add lib/iso_media/defragment.ex lib/iso_media.ex test/iso_media/defragment_test.exs CLAUDE.md
git commit -m "feat: ISOMedia.defragment/1 (fMP4 -> progressive), with byte-equivalence proof"
```

---

## Final verification

- [ ] **Full guarantee sweep**

Run: `mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: 0 failures, format clean, no warnings.

---

## Spec coverage check

- `trex`/`tfhd`/`tfdt`/`trun` decoders → Task 1.
- `samples/2` dispatch via `FragmentIndex.fragmented?/1` → Task 2.
- Cascade solver (trun→tfhd→trex, signed v1 comp offsets, sync bit) → Tasks 1+3.
- Tree-local offset invariant (moof-relative, default-base-is-moof, raise on unsupported) → Task 4.
- `chunk_index` per `trun` → Task 4.
- Eager `[%Sample{}]` output → Tasks 3+4 (no streaming seam — deferred).
- Real fixture, multi-track, lazy==eager, encrypted raise → Tasks 5+7.
- `defragment/1` via existing encoders + segment-list `mdat` → Tasks 6+7.
- Byte-for-byte equivalence headline → Task 7.
- Deferred (streaming seam, packed index, fragmenting, CENC, out-of-order) → not implemented, by design.
```
