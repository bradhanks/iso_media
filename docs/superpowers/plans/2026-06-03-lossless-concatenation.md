# Lossless Concatenation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ISOMedia.concat([boxes1, boxes2, …])` — losslessly join N compatible clips end-to-end (append each track's samples, concatenate the sample tables, build one segment-list `mdat` referencing every input file), memory-safely.

**Architecture:** `ISOMedia.Concat` checks compatibility (byte-identical `stsd` + matching `mdhd` timescale per track, equal track counts), then per track concatenates the samples from every input and rebuilds the tables via the Phase-5 encoders. The new `mdat` is the inputs' chunk-runs in order (each input's runs sorted by original offset to preserve its interleave), each resolved from its own input via `MdatSource`. Offsets/co64/durations are computed the same way as `Trim`.

**Tech Stack:** Elixir 1.19 / OTP 29, ExUnit.

**Branch:** `feat/concat` (holds the approved spec at `docs/superpowers/specs/2026-06-02-lossless-concatenation-design.md`).

**Conventions:** end every commit message with:
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```
Keep the branch format-clean (`mix format`; a `style: mix format` commit is fine).

---

### Task 1: `ISOMedia.Concat.concat/1` + `ISOMedia.concat/1`

**Files:**
- Create: `lib/iso_media/concat.ex`
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media/concat_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/concat_test.exs`:

```elixir
defmodule ISOMedia.ConcatTest do
  use ExUnit.Case
  alias ISOMedia.Support.MP4Builder

  # Two compatible clips: same track count, identical stsd stub, same (mdhd) timescale.
  # clip A track 1 = samples <<1>>,<<2>>; track 2 = <<5>>. clip B track 1 = <<3>>,<<4>>; track 2 = <<6>>.
  defp clip(t1_samples, t2_samples) do
    specs = [
      %{id: 1, chunks: [t1_samples], durations: List.duplicate(10, length(t1_samples))},
      %{id: 2, chunks: [t2_samples], durations: List.duplicate(10, length(t2_samples))}
    ]

    %{binary: bin} = MP4Builder.build_tracks(specs)
    {:ok, boxes} = ISOMedia.parse(bin)
    boxes
  end

  test "concat appends every track's samples in order, byte-identical" do
    a = clip([<<1>>, <<2>>], [<<5>>])
    b = clip([<<3>>, <<4>>], [<<6>>])

    out = [a, b] |> ISOMedia.concat() |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    assert ISOMedia.track_ids(reparsed) == [1, 2]

    s1 = ISOMedia.samples(reparsed, 1)
    assert Enum.map(s1, &binary_part(out, &1.offset, &1.size)) == [<<1>>, <<2>>, <<3>>, <<4>>]
    # timeline is continuous: dts 0,10,20,30
    assert Enum.map(s1, & &1.dts) == [0, 10, 20, 30]

    s2 = ISOMedia.samples(reparsed, 2)
    assert Enum.map(s2, &binary_part(out, &1.offset, &1.size)) == [<<5>>, <<6>>]
  end

  test "concat of a single clip returns it unchanged" do
    a = clip([<<1>>], [<<5>>])
    assert ISOMedia.concat([a]) == a
  end

  test "raises on an empty list" do
    assert_raise ArgumentError, fn -> ISOMedia.concat([]) end
  end

  test "raises when track counts differ" do
    a = clip([<<1>>], [<<5>>])
    {:ok, b} = ISOMedia.parse(MP4Builder.build_tracks([%{id: 1, chunks: [[<<3>>]], durations: [10]}]).binary)
    assert_raise ArgumentError, ~r/track count/, fn -> ISOMedia.concat([a, b]) end
  end

  test "raises when stsd differs between inputs" do
    a = clip([<<1>>], [<<5>>])
    b = clip([<<3>>], [<<6>>])
    # mutate b's track-1 stsd so it no longer matches a's
    bad_b =
      ISOMedia.Box.update(b, ~w(moov trak mdia minf stbl stsd), fn stsd ->
        %{stsd | data: <<0, 0, 0, 0, 1::32>>}
      end)

    assert_raise ArgumentError, ~r/stsd/, fn -> ISOMedia.concat([a, bad_b]) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/concat_test.exs`
Expected: FAIL — `ISOMedia.concat/1 is undefined`.

- [ ] **Step 3: Write the implementation**

Create `lib/iso_media/concat.ex`:

```elixir
defmodule ISOMedia.Concat do
  @moduledoc """
  Losslessly concatenate N compatible clips end-to-end.

  Inputs must have the same track count and, per track, byte-identical `stsd` and the
  same `mdhd` timescale (so sample tables can be appended without recomputation). For
  each track the samples of every input are appended (the timeline continues), the
  sample tables are rebuilt, and one `mdat` is assembled from every input's chunk-runs
  (each input's runs in original-offset order, preserving its interleave) — resolved
  from each input's own source via `MdatSource`. Source edit lists are ignored.
  """

  alias ISOMedia.{Box, Layout, MdatSource, SampleTable}
  alias ISOMedia.Boxes.{ChunkOffset, MediaHeader, MovieHeader, TrackHeader}

  @uint32_max 0xFFFFFFFF

  @doc "Concatenate a list of parsed trees into one. Returns a new box tree."
  def concat([]), do: raise(ArgumentError, "concat: empty input list")
  def concat([single]), do: single

  def concat([first | _] = inputs) do
    check_compatibility!(inputs)

    ftyp = Enum.find(first, &(&1.type == "ftyp")) || raise ArgumentError, "first input has no ftyp"
    first_moov = Enum.find(first, &(&1.type == "moov")) || raise ArgumentError, "first input has no moov"
    movie_ts = movie_timescale(first_moov)
    track_count = length(traks(first_moov))

    inputs_data =
      Enum.map(inputs, fn boxes ->
        moov = Enum.find(boxes, &(&1.type == "moov"))
        tks = traks(moov)
        %{samples: Enum.map(tks, &SampleTable.build/1), mdats: MdatSource.collect(boxes)}
      end)

    # All chunk-runs across all inputs, in input order, each input's runs sorted by
    # original offset (preserving that input's interleave).
    tagged =
      Enum.flat_map(inputs_data, fn d ->
        d.samples
        |> Enum.with_index()
        |> Enum.flat_map(fn {samples, ti} ->
          samples
          |> Enum.chunk_by(& &1.chunk_index)
          |> Enum.map(fn run ->
            %{track_i: ti, mdats: d.mdats, offset: hd(run).offset, length: Enum.sum(Enum.map(run, & &1.size))}
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
        Layout.box_size(assemble_moov(first_moov, inputs_data, track_count, dummy.(), :co64, movie_ts)) +
        16 + total

    co_kind = if bound > @uint32_max, do: :co64, else: :stco

    moov0 = assemble_moov(first_moov, inputs_data, track_count, dummy.(), co_kind, movie_ts)
    mdat_payload_start = Layout.box_size(ftyp) + Layout.box_size(moov0) + mdat_header

    {placed, _} =
      Enum.map_reduce(tagged, mdat_payload_start, fn run, pos ->
        {Map.put(run, :new_offset, pos), pos + run.length}
      end)

    offsets_by_track =
      Map.new(0..(track_count - 1)//1, fn ti ->
        {ti, placed |> Enum.filter(&(&1.track_i == ti)) |> Enum.map(& &1.new_offset)}
      end)

    moov_final = assemble_moov(first_moov, inputs_data, track_count, offsets_by_track, co_kind, movie_ts)
    segments = Enum.map(placed, fn run -> MdatSource.segment(run.mdats, run.offset, run.length) end)
    mdat = %Box{type: "mdat", data: segments, size_mode: mdat_mode}

    [ftyp, moov_final, mdat]
  end

  # --- compatibility ---

  defp check_compatibility!([first | rest]) do
    fmoov = moov_of(first)
    ftraks = traks(fmoov)
    count = length(ftraks)

    Enum.each(rest, fn boxes ->
      if length(traks(moov_of(boxes))) != count,
        do: raise(ArgumentError, "concat: inputs have different track count")
    end)

    for ti <- 0..(count - 1)//1 do
      ref_stsd = stsd_data(Enum.at(ftraks, ti))
      ref_ts = track_timescale(Enum.at(ftraks, ti))

      Enum.each(rest, fn boxes ->
        t = Enum.at(traks(moov_of(boxes)), ti)

        if stsd_data(t) != ref_stsd,
          do: raise(ArgumentError, "concat: track #{ti + 1} stsd differs between inputs (incompatible codec config)")

        if track_timescale(t) != ref_ts,
          do: raise(ArgumentError, "concat: track #{ti + 1} timescale differs between inputs")
      end)
    end
  end

  # --- moov / trak rebuild ---

  defp assemble_moov(first_moov, inputs_data, track_count, offsets_by_track, co_kind, movie_ts) do
    base_traks = traks(first_moov)

    joined =
      for ti <- 0..(track_count - 1)//1 do
        base = Enum.at(base_traks, ti)
        samples = Enum.flat_map(inputs_data, &Enum.at(&1.samples, ti))

        run_lengths =
          Enum.flat_map(inputs_data, fn d ->
            Enum.at(d.samples, ti) |> Enum.chunk_by(& &1.chunk_index) |> Enum.map(&length/1)
          end)

        build_joined_trak(base, samples, run_lengths, Map.fetch!(offsets_by_track, ti), co_kind, track_timescale(base), movie_ts)
      end

    movie_dur =
      for ti <- 0..(track_count - 1)//1 do
        samples = Enum.flat_map(inputs_data, &Enum.at(&1.samples, ti))
        scale(Enum.sum(Enum.map(samples, & &1.duration)), track_timescale(Enum.at(base_traks, ti)), movie_ts)
      end
      |> Enum.max(fn -> 0 end)

    children =
      first_moov.children
      |> Enum.reject(&(&1.type == "trak"))
      |> Enum.map(fn
        %Box{type: "mvhd"} = mvhd -> set_mvhd_duration(mvhd, movie_dur)
        other -> other
      end)

    %{first_moov | children: insert_traks(children, joined)}
  end

  defp build_joined_trak(base, samples, run_lengths, stco_offsets, co_kind, track_ts, movie_ts) do
    track_dur = Enum.sum(Enum.map(samples, & &1.duration))

    stsd = dig(base, ~w(mdia minf stbl stsd)) || raise ArgumentError, "track missing stsd"
    stts = SampleTable.build_stts(Enum.map(samples, & &1.duration))
    ctts = SampleTable.build_ctts(Enum.map(samples, &(&1.pts - &1.dts)))
    stsz = SampleTable.build_stsz(Enum.map(samples, & &1.size))
    stsc = SampleTable.build_stsc(run_lengths)
    stco = ChunkOffset.encode(%ChunkOffset{kind: co_kind, version: 0, flags: <<0, 0, 0>>, offsets: stco_offsets})
    stss = if Enum.all?(samples, & &1.sync?), do: nil, else: SampleTable.build_stss(sync_positions(samples))

    stbl_children = [stsd, stts] ++ opt(ctts) ++ [stsc, stsz] ++ opt(stss) ++ [stco]

    base
    |> put_stbl(stbl_children)
    |> drop_edts()
    |> update_descendant(~w(mdia mdhd), &set_mdhd_duration(&1, track_dur))
    |> update_descendant(["tkhd"], &set_tkhd_duration(&1, scale(track_dur, track_ts, movie_ts)))
  end

  defp sync_positions(samples) do
    samples
    |> Enum.with_index(1)
    |> Enum.filter(fn {s, _} -> s.sync? end)
    |> Enum.map(&elem(&1, 1))
  end

  # --- small helpers ---

  defp moov_of(boxes), do: Enum.find(boxes, &(&1.type == "moov")) || raise(ArgumentError, "input has no moov")
  defp traks(moov), do: Enum.filter(moov.children, &(&1.type == "trak"))
  defp stsd_data(trak), do: (dig(trak, ~w(mdia minf stbl stsd)) || raise(ArgumentError, "track missing stsd")).data
  defp track_timescale(trak), do: MediaHeader.decode(dig(trak, ~w(mdia mdhd))).timescale

  defp movie_timescale(moov) do
    case dig(moov, ["mvhd"]) do
      %Box{} = mvhd -> MovieHeader.decode(mvhd).timescale
      nil -> 1
    end
  end

  defp scale(value, from_ts, to_ts), do: round(value * to_ts / from_ts)
  defp opt(nil), do: []
  defp opt(box), do: [box]

  defp drop_edts(trak), do: %{trak | children: Enum.reject(trak.children, &(&1.type == "edts"))}

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

  defp insert_traks(children, traks) do
    idx = Enum.find_index(children, &(&1.type == "mvhd"))
    at = if idx, do: idx + 1, else: 0
    {pre, post} = Enum.split(children, at)
    pre ++ traks ++ post
  end

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

In `lib/iso_media.ex`, add (after `trim/3`):

```elixir
  @doc "Losslessly concatenate compatible clips end-to-end. See `ISOMedia.Concat.concat/1`."
  def concat(inputs) when is_list(inputs), do: ISOMedia.Concat.concat(inputs)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/iso_media/concat_test.exs`
Expected: PASS (5 tests). (If a byte/dts assertion fails, the append/offset math or `MdatSource` resolution is wrong — debug `Concat`, do not weaken.)

- [ ] **Step 6: Full suite + format + commit**

Run: `mix test && mix format && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: green, clean, no warnings.

```bash
git add lib/iso_media/concat.ex lib/iso_media.ex test/iso_media/concat_test.exs
git commit -m "feat: lossless concat/1 (append tracks, multi-source mdat)"
```

---

### Task 2: Real-fixture concat + property + docs

**Files:**
- Create: `test/iso_media/concat_av_test.exs`, `test/iso_media/concat_property_test.exs`
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Write the real-fixture test**

Create `test/iso_media/concat_av_test.exs`:

```elixir
defmodule ISOMedia.ConcatAvTest do
  use ExUnit.Case

  @fixture Path.join([__DIR__, "..", "fixtures", "sample_av.mp4"])

  test "concat a real file with itself doubles every track, byte-identical, continuous" do
    original = File.read!(@fixture)
    {:ok, a} = ISOMedia.parse(original)
    {:ok, b} = ISOMedia.parse(original)

    out = [a, b] |> ISOMedia.concat() |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    assert ISOMedia.track_ids(reparsed) == ISOMedia.track_ids(a)

    for id <- ISOMedia.track_ids(reparsed) do
      orig_samples = ISOMedia.samples(a, id)
      out_samples = ISOMedia.samples(reparsed, id)

      # doubled count
      assert length(out_samples) == 2 * length(orig_samples)

      # bytes: out = (orig samples) ++ (orig samples)
      expected = Enum.map(orig_samples, &binary_part(original, &1.offset, &1.size))
      got = Enum.map(out_samples, &binary_part(out, &1.offset, &1.size))
      assert got == expected ++ expected

      # continuous timeline: dts strictly non-decreasing across the splice
      dts = Enum.map(out_samples, & &1.dts)
      assert dts == Enum.sort(dts)
    end
  end

  test "lazy concat streams and matches eager" do
    eager_out =
      with {:ok, a} <- ISOMedia.parse(File.read!(@fixture)),
           {:ok, b} <- ISOMedia.parse(File.read!(@fixture)),
           do: [a, b] |> ISOMedia.concat() |> ISOMedia.serialize()

    {:ok, la} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    {:ok, lb} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    out = Path.join(System.tmp_dir!(), "iso_concat_#{System.unique_integer([:positive])}.mp4")
    on_exit(fn -> File.rm(out) end)

    assert :ok = ISOMedia.write(out, ISOMedia.concat([la, lb]))
    assert File.read!(out) == eager_out
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/iso_media/concat_av_test.exs`
Expected: PASS (2 tests). (A failure on the real file means the append/offset math is wrong on real data — debug, do not weaken. The lazy test confirms multi-source segment lists stream correctly.)

- [ ] **Step 3: Write the property test**

Create `test/iso_media/concat_property_test.exs`:

```elixir
defmodule ISOMedia.ConcatPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Support.MP4Builder

  # Compatible clips: each has exactly 2 tracks; per clip the chunk shapes vary but
  # stsd (stub) and timescale are identical across all clips, so they concat losslessly.
  defp clip_gen do
    gen all(
          t1 <- list_of(binary(min_length: 1, max_length: 5), min_length: 1, max_length: 3),
          t2 <- list_of(binary(min_length: 1, max_length: 5), min_length: 1, max_length: 3)
        ) do
      specs = [
        %{id: 1, chunks: [t1], durations: List.duplicate(10, length(t1))},
        %{id: 2, chunks: [t2], durations: List.duplicate(10, length(t2))}
      ]

      %{t1: t1, t2: t2, binary: MP4Builder.build_tracks(specs).binary}
    end
  end

  property "concat of N clips appends every track's samples byte-identically" do
    check all(clips <- list_of(clip_gen(), min_length: 2, max_length: 4)) do
      parsed = Enum.map(clips, fn %{binary: bin} -> {:ok, b} = ISOMedia.parse(bin); b end)

      out = parsed |> ISOMedia.concat() |> ISOMedia.serialize()
      {:ok, reparsed} = ISOMedia.parse(out)

      assert ISOMedia.track_ids(reparsed) == [1, 2]

      expected1 = Enum.flat_map(clips, & &1.t1)
      expected2 = Enum.flat_map(clips, & &1.t2)

      got1 = ISOMedia.samples(reparsed, 1) |> Enum.map(&binary_part(out, &1.offset, &1.size))
      got2 = ISOMedia.samples(reparsed, 2) |> Enum.map(&binary_part(out, &1.offset, &1.size))

      assert got1 == expected1
      assert got2 == expected2
    end
  end
end
```

- [ ] **Step 4: Run the property suite**

Run: `mix test test/iso_media/concat_property_test.exs`
Expected: PASS (1 property). (A failure is a real concat/offset bug — StreamData shrinks; debug, don't weaken.)

- [ ] **Step 5: Update the README**

In `README.md`, add after the "## Trim" section:

```markdown
## Concatenate

Join compatible clips end-to-end, losslessly:

```elixir
clips = Enum.map(["a.mp4", "b.mp4", "c.mp4"], fn p -> {:ok, b} = ISOMedia.read(p); b end)
ISOMedia.write("joined.mp4", ISOMedia.concat(clips))
```

Clips must be compatible: same track count, and per track a byte-identical `stsd`
(same codec/resolution/settings) and the same media timescale — otherwise it raises
(lossless concat can't reconcile different encodings). Source edit lists are ignored,
so concatenating clips that were previously **trimmed** will make their hidden
keyframe lead-in frames visible at each splice. Inputs must be freshly read files; to
concat the output of `trim`/`extract`/`concat`, write it to disk and read it back.
```

- [ ] **Step 6: Update CLAUDE.md**

In `CLAUDE.md`, add to the `## Architecture` module list:

```markdown
- `ISOMedia.Concat` (`lib/iso_media/concat.ex`) — `concat/1`: lossless end-to-end join of N compatible clips (byte-identical `stsd` + matching timescale required); appends each track's samples + tables, builds a multi-source segment-list `mdat`. Exposed as `ISOMedia.concat/1`.
```

- [ ] **Step 7: Verify + commit**

Run: `mix test && mix compile --warnings-as-errors && mix format --check-formatted`
Expected: green, clean.

```bash
git add test/iso_media/concat_av_test.exs test/iso_media/concat_property_test.exs README.md CLAUDE.md
git commit -m "test: concat real-fixture + property suites; docs for concat"
```

---

## Self-Review Notes

- **Spec coverage:** compatibility (track count + per-track `stsd` byte-identity + timescale) (T1 `check_compatibility!`); N inputs, single-passthrough, empty-raise (T1); per-track sample append + table rebuild via encoders (T1 `build_joined_trak`); multi-source segment-list `mdat` with per-input interleave preserved (T1 `tagged`/`MdatSource`); up-front co64/header + moov sizing + offset assignment + durations (T1, mirrors Trim); real-fixture concat-with-itself + lazy==eager (T2); property over N compatible clips (T2); docs incl. the trimmed-lead-in and chaining caveats (T2). Out-of-scope (stsd reconcile, elst merge, chaining without round-trip) excluded.
- **Type consistency:** reuses `SampleTable.build` + `build_stts/stsz/ctts/stss/stsc`, `MdatSource.collect/segment`, `ChunkOffset`/`MovieHeader`/`TrackHeader`/`MediaHeader` `decode`/`encode`, `Layout.box_size`. `sync_positions/1` computed from the concatenated sample list (the concatenation IS the per-input shift). `run_lengths` computed per-input then concatenated (NOT `chunk_by` on the merged list — that would wrongly merge a trailing chunk of one input with a leading chunk of the next when chunk indices coincide).
- **DRY note:** `dig`/`update_descendant`/`scale`/`opt`/`put_stbl`/the duration setters are duplicated from `Trim` (3rd copy of the descendant helpers across Extract/Trim/Concat). Acceptable for this isolated phase; a follow-up could factor them into a shared `ISOMedia.BoxPath`. (Flagged, not done.)
- **Placeholders:** none — every code/test step is complete and final as written.
