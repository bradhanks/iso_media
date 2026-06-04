# Fragmenting (progressive → fMP4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ISOMedia.fragment(boxes, target_duration: 2.0)` repacks a progressive MP4 into a single multiplexed fragmented tree `[ftyp, moov(+mvex), moof, mdat, …]` — keyframe-aligned, lossless (segment-list `mdat`s), memory-safe.

**Architecture:** Add `encode/1` to the Phase 9 decode-only fMP4 box views, then `ISOMedia.Fragment` reads progressive samples (`ISOMedia.samples/2`), picks keyframe boundaries from the first video track snapped to a duration target, windows every track at those times, and builds one `moof`+`mdat` per fragment — `trun.data_offset` resolved by a two-pass `Layout.box_size/1` measurement (the encoding inverse of Phase 9's tree-local offset invariant). Verified by the round trip `defragment(fragment(x))` reproducing `x`'s per-sample timing + bytes.

**Tech Stack:** Elixir, ExUnit, `Bitwise`, `ffmpeg` (fixture). No new deps.

---

## File structure

**Modified (add `encode/1`):**
- `lib/iso_media/boxes/track_extends.ex`, `track_fragment_decode_time.ex`, `track_fragment_header.ex`, `track_run.ex`

**Created:**
- `lib/iso_media/fragment.ex` — `fragment/2`, boundaries, windowing, fragment assembly
- Modify `lib/iso_media.ex` — `fragment/2` delegator

**Tests created:**
- `test/iso_media/boxes/fragment_encode_test.exs` — encoder round trips
- `test/iso_media/fragment_test.exs` — boundaries, windowing, structural, headline round trip
- Fixture: `test/fixtures/sample_keyint.mp4`

`Sample` fields (from `lib/iso_media/sample.ex`): `index, chunk_index, dts, duration, pts, size, offset, sync?`.

---

## Task 1: `encode/1` for trex / tfdt / tfhd / trun

**Files:**
- Modify: `lib/iso_media/boxes/track_extends.ex`, `track_fragment_decode_time.ex`, `track_fragment_header.ex`, `track_run.ex`
- Test: `test/iso_media/boxes/fragment_encode_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/boxes/fragment_encode_test.exs`:

```elixir
defmodule ISOMedia.Boxes.FragmentEncodeTest do
  use ExUnit.Case
  alias ISOMedia.Boxes.{TrackExtends, TrackFragmentDecodeTime, TrackFragmentHeader, TrackRun}

  test "trex encode/decode round-trips" do
    x = %TrackExtends{
      track_id: 2,
      default_sample_description_index: 1,
      default_sample_duration: 3000,
      default_sample_size: 1024,
      default_sample_flags: 0x01010000
    }

    assert TrackExtends.decode(TrackExtends.encode(x)) == x
  end

  test "tfdt v1 encode/decode round-trips" do
    x = %TrackFragmentDecodeTime{version: 1, base_media_decode_time: 9_000_000_000}
    assert TrackFragmentDecodeTime.decode(TrackFragmentDecodeTime.encode(x)) == x
  end

  test "tfhd (default-base-is-moof, no optionals) round-trips" do
    x = %TrackFragmentHeader{
      track_id: 7,
      base_data_offset: nil,
      sample_description_index: nil,
      default_sample_duration: nil,
      default_sample_size: nil,
      default_sample_flags: nil,
      default_base_is_moof?: true
    }

    assert TrackFragmentHeader.decode(TrackFragmentHeader.encode(x)) == x
  end

  test "trun without composition offsets round-trips (v0)" do
    x = %TrackRun{
      version: 0,
      sample_count: 2,
      data_offset: 158,
      first_sample_flags: nil,
      samples: [
        %{duration: 100, size: 500, flags: 0x00010000, composition_offset: nil},
        %{duration: 100, size: 480, flags: 0x00010000, composition_offset: nil}
      ]
    }

    assert TrackRun.decode(TrackRun.encode(x)) == x
  end

  test "trun with composition offsets round-trips (v1, signed)" do
    x = %TrackRun{
      version: 1,
      sample_count: 2,
      data_offset: 200,
      first_sample_flags: nil,
      samples: [
        %{duration: 90, size: 300, flags: 0x00000000, composition_offset: 0},
        %{duration: 90, size: 310, flags: 0x00000000, composition_offset: -45}
      ]
    }

    assert TrackRun.decode(TrackRun.encode(x)) == x
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/boxes/fragment_encode_test.exs`
Expected: FAIL — `encode/1` undefined for all four.

- [ ] **Step 3: Add the encoders**

`lib/iso_media/boxes/track_extends.ex` — add before the final `end`:

```elixir
  @doc "Encode a `%TrackExtends{}` back into a `trex` box."
  def encode(%__MODULE__{} = t) do
    body =
      <<t.track_id::32, t.default_sample_description_index::32, t.default_sample_duration::32,
        t.default_sample_size::32, t.default_sample_flags::32>>

    %Box{type: "trex", data: IO.iodata_to_binary(FullBox.encode(0, <<0, 0, 0>>, body))}
  end
```

`lib/iso_media/boxes/track_fragment_decode_time.ex` — add before the final `end`:

```elixir
  @doc "Encode a `%TrackFragmentDecodeTime{}` back into a `tfdt` box."
  def encode(%__MODULE__{version: version, base_media_decode_time: t}) do
    body = encode_time(version, t)
    %Box{type: "tfdt", data: IO.iodata_to_binary(FullBox.encode(version, <<0, 0, 0>>, body))}
  end

  defp encode_time(0, t), do: <<t::32>>
  defp encode_time(1, t), do: <<t::64>>
```

`lib/iso_media/boxes/track_fragment_header.ex` — add before the final `end` (this minimal encoder emits exactly `track_id` + the `default-base-is-moof` flag, which is all Phase 10 produces):

```elixir
  @doc "Encode a `%TrackFragmentHeader{}` (track_id + default-base-is-moof) into a `tfhd` box."
  def encode(%__MODULE__{track_id: track_id, default_base_is_moof?: true}) do
    body = <<track_id::32>>

    %Box{
      type: "tfhd",
      data: IO.iodata_to_binary(FullBox.encode(0, <<@default_base_is_moof::24>>, body))
    }
  end
```

`lib/iso_media/boxes/track_run.ex` — add before the final `end`:

```elixir
  @doc """
  Encode a `%TrackRun{}` into a `trun` box. Always writes data-offset + per-sample
  duration/size/flags; writes composition offsets (v1, signed) iff any sample has a
  nonzero offset.
  """
  def encode(%__MODULE__{} = t) do
    has_comp = Enum.any?(t.samples, &((&1.composition_offset || 0) != 0))
    version = if has_comp, do: 1, else: 0

    flags =
      @data_offset ||| @sample_duration ||| @sample_size ||| @sample_flags |||
        if has_comp, do: @sample_comp_offset, else: 0

    samples =
      for s <- t.samples, into: <<>> do
        base = <<s.duration::32, s.size::32, s.flags::32>>

        if has_comp,
          do: base <> <<(s.composition_offset || 0)::signed-32>>,
          else: base
      end

    body = <<length(t.samples)::32, t.data_offset::signed-32, samples::binary>>
    %Box{type: "trun", data: IO.iodata_to_binary(FullBox.encode(version, <<flags::24>>, body))}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/boxes/fragment_encode_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/boxes/track_extends.ex lib/iso_media/boxes/track_fragment_decode_time.ex lib/iso_media/boxes/track_fragment_header.ex lib/iso_media/boxes/track_run.ex test/iso_media/boxes/fragment_encode_test.exs
git commit -m "feat: encode/1 for trex/tfdt/tfhd/trun (inverse of Phase 9 decoders)"
```

---

## Task 2: Fragment boundary selection

**Files:**
- Create: `lib/iso_media/fragment.ex`
- Test: `test/iso_media/fragment_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/fragment_test.exs`:

```elixir
defmodule ISOMedia.FragmentTest do
  use ExUnit.Case
  alias ISOMedia.{Fragment, Sample}

  defp s(dts, sync?), do: %Sample{index: 0, chunk_index: 1, dts: dts, duration: 10, pts: dts, size: 5, offset: 0, sync?: sync?}

  describe "boundaries/2" do
    test "sparse keyframes: a boundary at the first sync >= last + target" do
      # keyframes at dts 0, 30, 60, 90; others non-sync
      samples =
        for d <- 0..90//10 do
          s(d, rem(d, 30) == 0)
        end

      # target 25: boundaries at 0, 30, 60, 90 (each next keyframe past +25)
      assert Fragment.boundaries(samples, 25) == [0, 30, 60, 90]
      # target 35: skip the keyframe at 30 (0+35=35 > 30), take 60, then 90
      assert Fragment.boundaries(samples, 35) == [0, 60]
    end

    test "all-sync (audio): boundaries purely by duration" do
      samples = for d <- 0..90//10, do: s(d, true)
      assert Fragment.boundaries(samples, 30) == [0, 30, 60, 90]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/fragment_test.exs`
Expected: FAIL — `Fragment` does not exist.

- [ ] **Step 3: Create `Fragment` with `boundaries/2`**

Create `lib/iso_media/fragment.ex` (no aliases yet — each later task adds exactly the aliases its code uses, enforced by the warnings gate):

```elixir
defmodule ISOMedia.Fragment do
  @moduledoc """
  Repack a progressive MP4 into a single multiplexed fragmented tree
  `[ftyp, moov(+mvex), moof, mdat, …]`. Keyframe-aligned (a fragment starts on a sync
  sample so it is independently decodable), lossless (sample bytes via a Phase 8
  segment-list `mdat`), memory-safe. The inverse of `ISOMedia.Defragment`.
  """

  @doc """
  Boundary dts values (in the given samples' timescale): greedily take the first sync
  sample, then each next sync sample whose dts ≥ previous boundary + `target_ts`.
  """
  def boundaries(samples, target_ts) do
    syncs = Enum.filter(samples, & &1.sync?)

    {rev, _last} =
      Enum.reduce(syncs, {[], nil}, fn s, {acc, last} ->
        if last == nil or s.dts >= last + target_ts,
          do: {[s.dts | acc], s.dts},
          else: {acc, last}
      end)

    Enum.reverse(rev)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/fragment_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/fragment.ex test/iso_media/fragment_test.exs
git commit -m "feat: Fragment.boundaries/2 (keyframe-aligned, duration-targeted)"
```

---

## Task 3: Per-track windowing

**Files:**
- Modify: `lib/iso_media/fragment.ex`
- Test: `test/iso_media/fragment_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/iso_media/fragment_test.exs`:

```elixir
  describe "windows/2" do
    test "partitions samples into [b_i, b_{i+1}) by dts" do
      samples = for d <- 0..90//10, do: s(d, true)
      # boundaries 0, 40, 80 -> windows [0..30], [40..70], [80..90]
      windows = Fragment.windows(samples, [0, 40, 80])
      assert Enum.map(windows, fn run -> Enum.map(run, & &1.dts) end) ==
               [[0, 10, 20, 30], [40, 50, 60, 70], [80, 90]]
    end

    test "a track with no samples in a window yields an empty run there" do
      samples = [s(0, true), s(50, true)]
      windows = Fragment.windows(samples, [0, 20, 40])
      assert Enum.map(windows, &length/1) == [1, 0, 1]
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/fragment_test.exs`
Expected: FAIL — `windows/2` undefined.

- [ ] **Step 3: Add `windows/2`**

In `lib/iso_media/fragment.ex`, add after `boundaries/2`:

```elixir
  @doc """
  Partition `samples` into one run per boundary: run `i` is the samples whose dts is in
  `[boundaries[i], boundaries[i+1])` (the last run is open-ended). `boundaries` must be in
  the same timescale as the samples, ascending.
  """
  def windows(samples, boundaries) do
    boundaries
    |> Enum.with_index()
    |> Enum.map(fn {b, i} ->
      next = Enum.at(boundaries, i + 1)
      Enum.filter(samples, fn s -> s.dts >= b and (next == nil or s.dts < next) end)
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/fragment_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/fragment.ex test/iso_media/fragment_test.exs
git commit -m "feat: Fragment.windows/2 (partition samples by boundary dts)"
```

---

## Task 4: Single-fragment moof + mdat assembly (two-pass data_offset)

**Files:**
- Modify: `lib/iso_media/fragment.ex`
- Test: `test/iso_media/fragment_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/iso_media/fragment_test.exs`:

```elixir
  describe "build_fragment/4 (data_offset invariant)" do
    test "trun data_offset points exactly into the sibling mdat payload" do
      # one track, 2 samples of 10 bytes each, sourced from an in-memory mdat
      payload = for(i <- 0..19, into: <<>>, do: <<i>>)
      src_mdat = %ISOMedia.Box{type: "mdat", size_mode: :compact, data: payload}
      mdats = ISOMedia.MdatSource.collect([src_mdat])

      run = [
        %Sample{index: 1, chunk_index: 1, dts: 0, duration: 5, pts: 0, size: 10, offset: 8, sync?: true},
        %Sample{index: 2, chunk_index: 1, dts: 5, duration: 5, pts: 5, size: 10, offset: 18, sync?: true}
      ]

      metas = [%{track_id: 1, timescale: 1000, handler: "vide", samples: run, trak: nil}]
      {moof, mdat} = Fragment.build_fragment(1, [run], metas, mdats)

      trex =
        ISOMedia.Boxes.TrackExtends.encode(%ISOMedia.Boxes.TrackExtends{
          track_id: 1,
          default_sample_description_index: 1,
          default_sample_duration: 0,
          default_sample_size: 0,
          default_sample_flags: 0
        })

      # the moof+mdat must be a self-consistent fragment: parse it back via FragmentIndex.
      tree = [
        %ISOMedia.Box{type: "ftyp", data: <<"isom", 0::32>>},
        %ISOMedia.Box{type: "moov", children: [%ISOMedia.Box{type: "mvex", children: [trex]}]},
        moof,
        mdat
      ]

      samples = ISOMedia.FragmentIndex.samples(tree, 1)
      assert Enum.map(samples, & &1.size) == [10, 10]
      assert Enum.map(samples, & &1.dts) == [0, 5]
      # resolved bytes equal the original payload bytes for each sample
      recs = ISOMedia.MdatSource.collect(tree)

      bytes =
        Enum.map(samples, fn smp ->
          seg = ISOMedia.MdatSource.segment(recs, smp.offset, smp.size)
          ISOMedia.Box.read_data(%ISOMedia.Box{type: "x", data: List.wrap(seg)})
        end)

      assert IO.iodata_to_binary(bytes) == payload
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/fragment_test.exs`
Expected: FAIL — `build_fragment/4` undefined.

- [ ] **Step 3: Implement `build_fragment/4` + helpers**

In `lib/iso_media/fragment.ex`, add the alias block under the moduledoc (exactly what Task 4's code uses; Task 5 widens it):

```elixir
  alias ISOMedia.{Box, Layout, MdatSource}
  alias ISOMedia.Boxes.{TrackFragmentDecodeTime, TrackFragmentHeader, TrackRun}

  @non_sync 0x00010000
```

Then add:

```elixir
  @doc false
  # Build one fragment's {moof, mdat} from per-track sample runs (aligned to `metas`).
  # data_offsets are resolved in two passes: build the moof with placeholder offsets to
  # learn its exact serialized size, then rebuild with real moof-relative offsets.
  def build_fragment(seq, runs_per_track, metas, mdats) do
    active =
      metas
      |> Enum.zip(runs_per_track)
      |> Enum.reject(fn {_m, run} -> run == [] end)

    moof0 = build_moof(seq, active, fn _i -> 0 end)
    payload_start = Layout.box_size(moof0) + 8

    {offsets, _} =
      Enum.map_reduce(active, payload_start, fn {_m, run}, pos ->
        {pos, pos + Enum.sum(Enum.map(run, & &1.size))}
      end)

    moof = build_moof(seq, active, fn i -> Enum.at(offsets, i) end)

    segments =
      Enum.flat_map(active, fn {_m, run} ->
        Enum.map(run, fn smp -> MdatSource.segment(mdats, smp.offset, smp.size) end)
      end)

    {moof, %Box{type: "mdat", size_mode: :compact, data: segments}}
  end

  defp build_moof(seq, active, offset_fun) do
    mfhd = %Box{type: "mfhd", data: <<0::32, seq::32>>}

    trafs =
      active
      |> Enum.with_index()
      |> Enum.map(fn {{meta, run}, i} -> build_traf(meta, run, offset_fun.(i)) end)

    %Box{type: "moof", children: [mfhd | trafs]}
  end

  defp build_traf(meta, run, data_offset) do
    tfhd =
      TrackFragmentHeader.encode(%TrackFragmentHeader{
        track_id: meta.track_id,
        default_base_is_moof?: true
      })

    tfdt =
      TrackFragmentDecodeTime.encode(%TrackFragmentDecodeTime{
        version: 1,
        base_media_decode_time: hd(run).dts
      })

    trun =
      TrackRun.encode(%TrackRun{
        version: 0,
        sample_count: length(run),
        data_offset: data_offset,
        first_sample_flags: nil,
        samples:
          Enum.map(run, fn smp ->
            %{
              duration: smp.duration,
              size: smp.size,
              flags: if(smp.sync?, do: 0, else: @non_sync),
              composition_offset: smp.pts - smp.dts
            }
          end)
      })

    %Box{type: "traf", children: [tfhd, tfdt, trun]}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/fragment_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/fragment.ex test/iso_media/fragment_test.exs
git commit -m "feat: Fragment.build_fragment/4 (moof+mdat, two-pass data_offset)"
```

---

## Task 5: `fragment/2` full assembly + init moov skeleton + delegator

**Files:**
- Modify: `lib/iso_media/fragment.ex`, `lib/iso_media.ex`
- Test: `test/iso_media/fragment_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/iso_media/fragment_test.exs`:

```elixir
  describe "fragment/2 structure" do
    test "produces a valid multiplexed fMP4 tree from a progressive file" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
      out = ISOMedia.fragment(boxes, target_duration: 0.3)

      assert hd(out).type == "ftyp"
      assert Enum.at(out, 1).type == "moov"
      assert ISOMedia.FragmentIndex.fragmented?(out)

      moov = Enum.find(out, &(&1.type == "moov"))
      assert Enum.any?(moov.children, &(&1.type == "mvex"))
      # init trak stbl carries stsd but zero samples
      trak = Enum.find(moov.children, &(&1.type == "trak"))
      stbl = ISOMedia.BoxPath.dig(trak, ~w(mdia minf stbl))
      assert Enum.any?(stbl.children, &(&1.type == "stsd"))
      refute Enum.any?(trak.children, &(&1.type == "edts"))

      # the output re-serializes and re-parses cleanly
      assert {:ok, _} = ISOMedia.parse(ISOMedia.serialize(out))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/fragment_test.exs`
Expected: FAIL — `ISOMedia.fragment/2` undefined.

- [ ] **Step 3: Implement `fragment/2` + init-moov helpers, and the delegator**

In `lib/iso_media/fragment.ex`, **widen the alias block** to add the modules Task 5 uses:

```elixir
  alias ISOMedia.{Box, BoxPath, Layout, MdatSource, SampleTable}

  alias ISOMedia.Boxes.{
    ChunkOffset,
    Handler,
    MediaHeader,
    TrackExtends,
    TrackFragmentDecodeTime,
    TrackFragmentHeader,
    TrackHeader,
    TrackRun
  }
```

Then add `fragment/2` and helpers:

```elixir
  @doc "Repack a progressive tree into a multiplexed fragmented tree. `opts[:target_duration]` seconds (default 2.0)."
  def fragment(boxes, opts \\ []) do
    target_sec = Keyword.get(opts, :target_duration, 2.0)
    ftyp = Enum.find(boxes, &(&1.type == "ftyp")) || raise ArgumentError, "fragment: no ftyp"
    moov = Enum.find(boxes, &(&1.type == "moov")) || raise ArgumentError, "fragment: no moov"
    mdats = MdatSource.collect(boxes)

    metas =
      moov.children
      |> Enum.filter(&(&1.type == "trak"))
      |> Enum.map(fn trak ->
        tid = TrackHeader.decode(BoxPath.dig(trak, ["tkhd"])).track_id

        %{
          track_id: tid,
          timescale: MediaHeader.decode(BoxPath.dig(trak, ~w(mdia mdhd))).timescale,
          handler: Handler.decode(BoxPath.dig(trak, ~w(mdia hdlr))).handler_type,
          samples: ISOMedia.samples(boxes, tid),
          trak: trak
        }
      end)

    driver = Enum.find(metas, &(&1.handler == "vide")) || hd(metas)
    target_ts = round(target_sec * driver.timescale)
    bounds = boundaries(driver.samples, target_ts)

    windows_per_track =
      Enum.map(metas, fn m ->
        bts = Enum.map(bounds, fn b -> scale(b, driver.timescale, m.timescale) end)
        windows(m.samples, bts)
      end)

    moof_mdats =
      bounds
      |> Enum.with_index()
      |> Enum.flat_map(fn {_b, i} ->
        runs_per_track = Enum.map(windows_per_track, &Enum.at(&1, i))
        {moof, mdat} = build_fragment(i + 1, runs_per_track, metas, mdats)
        [moof, mdat]
      end)

    [ftyp, build_init_moov(moov, metas) | moof_mdats]
  end

  defp build_init_moov(moov, metas) do
    mvhd = Enum.find(moov.children, &(&1.type == "mvhd"))

    trex_boxes =
      Enum.map(metas, fn m ->
        TrackExtends.encode(%TrackExtends{
          track_id: m.track_id,
          default_sample_description_index: 1,
          default_sample_duration: 0,
          default_sample_size: 0,
          default_sample_flags: 0
        })
      end)

    mvex = %Box{type: "mvex", children: trex_boxes}
    init_traks = Enum.map(metas, fn m -> build_init_trak(m.trak) end)
    others = Enum.reject(moov.children, &(&1.type in ~w(trak mvhd)))
    children = Enum.reject([mvhd, mvex] ++ init_traks ++ others, &is_nil/1)
    %{moov | children: children}
  end

  defp build_init_trak(trak) do
    stsd = BoxPath.dig(trak, ~w(mdia minf stbl stsd)) || raise ArgumentError, "track missing stsd"

    empty = [
      stsd,
      SampleTable.build_stts([]),
      SampleTable.build_stsc([]),
      SampleTable.build_stsz([]),
      ChunkOffset.encode(%ChunkOffset{kind: :stco, version: 0, flags: <<0, 0, 0>>, offsets: []})
    ]

    trak
    |> Map.update!(:children, &Enum.reject(&1, fn c -> c.type == "edts" end))
    |> BoxPath.update_descendant(~w(mdia minf stbl), fn stbl -> %{stbl | children: empty} end)
  end

  # Integer round-half-up (no float precision loss for long media).
  defp scale(value, from_ts, to_ts), do: div(value * to_ts + div(from_ts, 2), from_ts)
```

In `lib/iso_media.ex`, add after the `defragment/1` delegator:

```elixir
  @doc "Repack a progressive tree into a multiplexed fragmented MP4. See `ISOMedia.Fragment.fragment/2`."
  def fragment(boxes, opts \\ []), do: ISOMedia.Fragment.fragment(boxes, opts)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/fragment_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/fragment.ex lib/iso_media.ex test/iso_media/fragment_test.exs
git commit -m "feat: ISOMedia.fragment/2 (progressive -> multiplexed fMP4)"
```

---

## Task 6: Keyframe fixture + headline round-trip proof + edge tests

**Files:**
- Add fixture: `test/fixtures/sample_keyint.mp4`
- Modify: `test/fixtures/README.md`, `CLAUDE.md`
- Test: `test/iso_media/fragment_test.exs`

- [ ] **Step 1: Generate the fixture**

Run (requires `ffmpeg`):

```bash
cd test/fixtures && ffmpeg -y -f lavfi -i testsrc=duration=2:size=128x96:rate=10 \
  -f lavfi -i sine=frequency=440:duration=2 \
  -pix_fmt yuv420p -c:a aac -g 10 -shortest sample_keyint.mp4
```

Append to `test/fixtures/README.md`:

```markdown

    # Frequent-keyframe progressive fixture for Phase 10 fragmenting (GOP 10 -> a
    # keyframe every 1s, so target_duration < 1s yields multiple fragments):
    ffmpeg -y -f lavfi -i testsrc=duration=2:size=128x96:rate=10 \
      -f lavfi -i sine=frequency=440:duration=2 \
      -pix_fmt yuv420p -c:a aac -g 10 -shortest sample_keyint.mp4
```

- [ ] **Step 2: Write the failing tests**

Append inside the module in `test/iso_media/fragment_test.exs`:

```elixir
  describe "round trip (the proof)" do
    @keyint "test/fixtures/sample_keyint.mp4"

    defp sample_bytes(boxes, samples) do
      recs = ISOMedia.MdatSource.collect(boxes)

      samples
      |> Enum.map(fn smp ->
        seg = ISOMedia.MdatSource.segment(recs, smp.offset, smp.size)
        ISOMedia.Box.read_data(%ISOMedia.Box{type: "x", data: List.wrap(seg)})
      end)
      |> IO.iodata_to_binary()
    end

    test "the keyint fixture yields >= 2 fragments and every fragment starts on a keyframe" do
      {:ok, boxes} = ISOMedia.read(@keyint)
      out = ISOMedia.fragment(boxes, target_duration: 0.3)
      assert Enum.count(out, &(&1.type == "moof")) >= 2
      [vid | _] = Enum.filter(ISOMedia.track_ids(boxes), fn tid ->
        # video track: more than a handful of samples, sparse sync
        s = ISOMedia.samples(boxes, tid)
        Enum.count(s, & &1.sync?) < length(s)
      end)
      # each fragment's first video sample is a keyframe
      frag = ISOMedia.samples(out, vid)
      firsts = frag |> Enum.group_by(& &1.chunk_index) |> Map.values() |> Enum.map(&hd/1)
      assert Enum.all?(firsts, & &1.sync?)
    end

    test "defragment(fragment(x)) reproduces per-sample timing and bytes" do
      {:ok, boxes} = ISOMedia.read(@keyint)
      round = boxes |> ISOMedia.fragment(target_duration: 0.3) |> ISOMedia.defragment()

      for tid <- ISOMedia.track_ids(boxes) do
        orig = ISOMedia.samples(boxes, tid)
        rt = ISOMedia.samples(round, tid)
        assert Enum.map(rt, & &1.dts) == Enum.map(orig, & &1.dts)
        assert Enum.map(rt, & &1.pts) == Enum.map(orig, & &1.pts)
        assert Enum.map(rt, & &1.size) == Enum.map(orig, & &1.size)
        assert Enum.map(rt, & &1.sync?) == Enum.map(orig, & &1.sync?)
        assert sample_bytes(round, rt) == sample_bytes(boxes, orig)
      end
    end

    test "audio-only fragments and round-trips" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample.m4a")
      out = ISOMedia.fragment(boxes, target_duration: 0.3)
      assert ISOMedia.FragmentIndex.fragmented?(out)
      round = ISOMedia.defragment(out)
      [tid] = ISOMedia.track_ids(boxes)
      assert Enum.map(ISOMedia.samples(round, tid), & &1.size) ==
               Enum.map(ISOMedia.samples(boxes, tid), & &1.size)
    end

    test "lazy and eager fragmenting produce identical bytes" do
      {:ok, eager} = ISOMedia.read(@keyint)
      {:ok, lazy} = ISOMedia.read(@keyint, lazy: true)
      assert ISOMedia.serialize(ISOMedia.fragment(eager)) ==
               ISOMedia.serialize(ISOMedia.fragment(lazy))
    end

    test "fragmenting a trimmed input strips edts from the init moov" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
      trimmed = ISOMedia.trim(boxes, 0.2, 0.8)
      out = ISOMedia.fragment(trimmed, target_duration: 0.3)
      moov = Enum.find(out, &(&1.type == "moov"))
      for trak <- Enum.filter(moov.children, &(&1.type == "trak")) do
        refute Enum.any?(trak.children, &(&1.type == "edts"))
      end
    end

    test "trailing sidx/mfra are opaque leaves and ignored by indexing" do
      {:ok, boxes} = ISOMedia.read(@keyint)
      out = ISOMedia.fragment(boxes, target_duration: 0.3)
      with_trailers = out ++ [%ISOMedia.Box{type: "sidx", data: <<0::96>>}, %ISOMedia.Box{type: "mfra", data: <<0::64>>}]
      assert [%ISOMedia.Box{type: "sidx", data: d}] = Enum.filter(with_trailers, &(&1.type == "sidx"))
      assert is_binary(d)
      # indexing still works with the trailers present
      [tid | _] = ISOMedia.track_ids(with_trailers)
      assert is_list(ISOMedia.samples(with_trailers, tid))
    end
  end
```

- [ ] **Step 3: Run tests to verify they pass (or surface a real bug)**

Run: `mix test test/iso_media/fragment_test.exs`
Expected: PASS. A round-trip byte/timing failure is a genuine fragmenting or data_offset bug — debug with `superpowers:systematic-debugging`; do not weaken assertions. If they pass immediately, confirm non-vacuity by perturbing a `data_offset` (e.g. `+ 1` in `build_fragment`'s `offsets`) and checking the round-trip test flips to FAIL, then revert.

- [ ] **Step 4: Update CLAUDE.md, run the full sweep, and commit**

Add a `ISOMedia.Fragment` bullet to `CLAUDE.md`'s architecture list (`fragment/2`: progressive → multiplexed fMP4, keyframe-aligned, two-pass `data_offset`, segment-list `mdat`; exposed as `ISOMedia.fragment/2`) and note the new `encode/1` on the fMP4 box views.

Run: `mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: 0 failures, format clean, no warnings.

```bash
git add test/fixtures/sample_keyint.mp4 test/fixtures/README.md test/iso_media/fragment_test.exs CLAUDE.md
git commit -m "test: keyint fixture; fragment->defragment round-trip proof + edge cases"
```

---

## Final verification

- [ ] **Full guarantee sweep**

Run: `mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: 0 failures, format clean, no warnings.

---

## Spec coverage check

- `encode/1` for `trex`/`tfdt`/`tfhd`/`trun` (+ inline `mfhd`) → Task 1 (+ Task 4's `build_moof`).
- `fragment/2`, single multiplexed output, `target_duration` → Tasks 5.
- Keyframe-aligned, duration-targeted boundaries; video track drives → Task 2 + 5.
- Per-track windowing at scaled boundary dts → Task 3 + 5.
- `default-base-is-moof`, all-explicit `trun`, `sample_flags` sync bit → Tasks 1, 4.
- Two-pass `data_offset` invariant → Task 4.
- `mvex`/`trex` synthesis, empty-`stbl` init skeleton, `drop_edts` → Task 5.
- Segment-list `mdat` via `MdatSource` → Task 4.
- Keyframe fixture, headline round trip, audio-only, lazy==eager, edts-stripped, sidx/mfra opaque, determinism teeth → Task 6.
- Deferred (separate segments/styp, manifests, trun default-compression, multi-video boundary, sidx/mfra emission) → not implemented, by design.
```
