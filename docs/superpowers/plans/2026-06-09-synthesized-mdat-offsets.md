# Synthesized-`mdat` Chunk Offsets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `fix_chunk_offsets/1` and `faststart/1` work on synthesized (segment-list) `mdat`s in memory — no-op when unmoved, correct uniform offset remap when relocated — instead of raising.

**Architecture:** Add one shared constructor `ISOMedia.MdatSource.synthesized_mdat/3` that builds a segment-list `mdat` and stamps `source_offset`/`source_size` (the basis its chunk offsets were written against). Swap it into the three progressive synthesizers (`ProgressiveBuild`, `Trim`, `Extract`). `ISOMedia.Offsets` is **not modified** — once the basis exists, the existing uniform-delta + `stco→co64` fixpoint machinery applies unchanged.

**Tech Stack:** Elixir, ExUnit. Pure, zero-dependency library. No DB/Phoenix/LiveView.

**Spec:** `docs/superpowers/specs/2026-06-09-synthesized-mdat-offsets-design.md` (phase doc: `docs/superpowers/specs/phase-1/2026-06-08-synthesized-mdat-offsets.md`).

**Branch:** `feat/synthesized-mdat-offsets`. Attribution is disabled — do **not** add a `Co-Authored-By` trailer to commits.

---

## File Structure

- **Modify** `lib/iso_media/mdat_source.ex` — add `Box` to the alias; add the public `synthesized_mdat/3` constructor. This module already owns synthesized-`mdat` resolution (`collect/1`, `segment/3`), so the constructor lives beside its resolver.
- **Modify** `lib/iso_media/progressive_build.ex:88` — one-line `mdat` swap (covers Concat + Defragment).
- **Modify** `lib/iso_media/trim.ex` — one-line `mdat` swap.
- **Modify** `lib/iso_media/extract.ex` — one-line `mdat` swap.
- **Modify** `lib/iso_media.ex` — moduledoc note (no behavior change).
- **Modify** `docs/ROADMAP.md`, `CLAUDE.md` — docs.
- **Test** `test/iso_media/mdat_source_test.exs` — unit tests for `synthesized_mdat/3`.
- **Test** `test/iso_media/offsets_test.exs` — integration tests (no-op, relocation, co64 promotion, idempotence, guard-still-raises) on a synthesized tree built from the `sample.mp4` fixture.

`lib/iso_media/offsets.ex` is **not touched** by design.

---

### Task 1: `MdatSource.synthesized_mdat/3` constructor

**Files:**
- Modify: `lib/iso_media/mdat_source.ex:8` (alias) and add a function after `collect/1`
- Test: `test/iso_media/mdat_source_test.exs`

- [ ] **Step 1: Write the failing unit test**

Add this `describe` block to `test/iso_media/mdat_source_test.exs` (the module already has `alias ISOMedia.{Box, FileSlice, MdatSource}`), after the existing `describe "collect/1" do ... end` block:

```elixir
  describe "synthesized_mdat/3" do
    test "stamps source_offset (box start) and source_size (box size) for a compact mdat" do
      segments = [<<1, 2, 3, 4>>]
      # payload_start 100 => box starts 8 bytes earlier (compact header); size = 8 + 4
      mdat = MdatSource.synthesized_mdat(segments, :compact, 100)

      assert %Box{type: "mdat", data: ^segments, size_mode: :compact} = mdat
      assert mdat.source_offset == 92
      assert mdat.source_size == 12
    end

    test "uses the large (16-byte) header for :large size_mode" do
      segments = [<<0, 0, 0, 0>>]
      # payload_start 200 => box starts 16 bytes earlier (large header); size = 16 + 4
      mdat = MdatSource.synthesized_mdat(segments, :large, 200)

      assert mdat.size_mode == :large
      assert mdat.source_offset == 184
      assert mdat.source_size == 20
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/iso_media/mdat_source_test.exs`
Expected: FAIL — `(UndefinedFunctionError) function ISOMedia.MdatSource.synthesized_mdat/3 is undefined`.

- [ ] **Step 3: Implement the constructor**

In `lib/iso_media/mdat_source.ex`, add `Box` to the alias on line 8:

```elixir
  alias ISOMedia.{Box, FileSlice, Layout}
```

Then add this function immediately after the `collect/1` function (after its closing `end`, before the `segment/3` `@doc`):

```elixir
  @doc """
  Build a synthesized segment-list `mdat`, stamped with the basis position its chunk
  offsets were written against. `payload_start` is the absolute byte offset of the mdat
  payload in the layout its offsets were baked for (what the builder already computed to
  place chunks). The stamp gives `ISOMedia.Offsets.fix_chunk_offsets/1` a basis, so the
  table can be remapped if the mdat later moves — no disk round-trip needed.
  """
  def synthesized_mdat(segments, size_mode, payload_start) do
    box = %Box{type: "mdat", data: segments, size_mode: size_mode}

    %{
      box
      | source_offset: payload_start - Layout.header_size(box),
        source_size: Layout.box_size(box)
    }
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/iso_media/mdat_source_test.exs`
Expected: PASS (all tests in the file, including the 2 new ones).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/mdat_source.ex test/iso_media/mdat_source_test.exs
git commit -m "feat: MdatSource.synthesized_mdat/3 stamps offset basis on synthesized mdats"
```

---

### Task 2: Swap the three synthesizers (driven by no-op + relocation tests)

**Files:**
- Modify: `lib/iso_media/progressive_build.ex:88`, `lib/iso_media/trim.ex` (the `mdat = %Box{...}` line), `lib/iso_media/extract.ex` (the `mdat = %Box{...}` line)
- Test: `test/iso_media/offsets_test.exs`

- [ ] **Step 1: Write the failing integration tests**

In `test/iso_media/offsets_test.exs`, add this module-level private helper next to the other helpers (e.g. after `stco_offsets/1`, before the first `test`):

```elixir
  # A synthesized progressive tree [ftyp, moov, mdat] from the real fixture, via
  # extract_track (its mdat is a segment list with no parsed source position).
  defp synth_track do
    original = File.read!(Path.join([__DIR__, "..", "fixtures", "sample.mp4"]))
    {:ok, boxes} = ISOMedia.parse(original)
    [tid | _] = ISOMedia.track_ids(boxes)
    synth = ISOMedia.extract_track(boxes, tid)
    [synth_tid | _] = ISOMedia.track_ids(synth)
    {synth, synth_tid}
  end
```

Then add this `describe` block at the end of the module (before the final `end`):

```elixir
  describe "synthesized mdat (in-memory fix/faststart)" do
    test "fix_chunk_offsets is a no-op on a freshly synthesized tree" do
      {synth, _tid} = synth_track()
      fixed = ISOMedia.fix_chunk_offsets(synth)
      assert ISOMedia.serialize(fixed) == ISOMedia.serialize(synth)
    end

    test "faststart is a no-op on a synthesized [ftyp, moov, mdat] tree" do
      {synth, _tid} = synth_track()
      assert ISOMedia.serialize(ISOMedia.faststart(synth)) == ISOMedia.serialize(synth)
    end

    test "fix_chunk_offsets remaps every sample to its correct bytes after the mdat moves" do
      {synth, tid} = synth_track()
      before_bin = ISOMedia.serialize(synth)
      expected = Enum.map(ISOMedia.samples(synth, tid), fn s ->
        :binary.part(before_bin, s.offset, s.size)
      end)

      # free box total size = 8 header + 4 data = 12; inserting before mdat shifts it down.
      moved = List.insert_at(synth, 2, %Box{type: "free", data: <<0, 0, 0, 0>>})
      fixed = ISOMedia.fix_chunk_offsets(moved)
      after_bin = ISOMedia.serialize(fixed)
      new_samples = ISOMedia.samples(fixed, tid)

      assert length(new_samples) == length(expected)

      Enum.zip(expected, new_samples)
      |> Enum.each(fn {bytes, s} ->
        assert :binary.part(after_bin, s.offset, s.size) == bytes
      end)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/iso_media/offsets_test.exs`
Expected: FAIL — the three new tests raise `(ArgumentError) fix_chunk_offsets: an mdat has no source position (synthesized?)...` (the synthesized `mdat` has no basis yet).

- [ ] **Step 3: Apply the three one-line swaps**

In `lib/iso_media/progressive_build.ex`, replace line 88:

```elixir
    mdat = %Box{type: "mdat", data: segments, size_mode: mdat_mode}
```

with:

```elixir
    mdat = MdatSource.synthesized_mdat(segments, mdat_mode, mdat_payload_start)
```

In `lib/iso_media/trim.ex`, replace the identical line (`mdat = %Box{type: "mdat", data: segments, size_mode: mdat_mode}`) with:

```elixir
    mdat = MdatSource.synthesized_mdat(segments, mdat_mode, mdat_payload_start)
```

In `lib/iso_media/extract.ex`, replace the identical line (`mdat = %Box{type: "mdat", data: segments, size_mode: mdat_mode}`) with:

```elixir
    mdat = MdatSource.synthesized_mdat(segments, mdat_mode, mdat_payload_start)
```

(All three modules already `alias ISOMedia.{Box, ..., MdatSource}` and have `mdat_payload_start` in scope at this line.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/iso_media/offsets_test.exs`
Expected: PASS (all tests, including the 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/progressive_build.ex lib/iso_media/trim.ex lib/iso_media/extract.ex test/iso_media/offsets_test.exs
git commit -m "feat: synthesized mdats carry an offset basis so fix_chunk_offsets/faststart work in memory"
```

---

### Task 3: Coverage — co64 promotion, idempotence, and the size-changed guard

**Files:**
- Test: `test/iso_media/offsets_test.exs`

These tests pass immediately on top of Task 2 (no new lib code) — they lock in the spec §7/§8 behaviors the swap enabled.

- [ ] **Step 1: Add the coverage tests**

Inside the `describe "synthesized mdat (in-memory fix/faststart)"` block added in Task 2, add three more tests:

```elixir
    test "promotes stco to co64 on a synthesized tree and samples still resolve" do
      {synth, tid} = synth_track()
      base = ISOMedia.serialize(synth)
      expected = Enum.map(ISOMedia.samples(synth, tid), fn s -> :binary.part(base, s.offset, s.size) end)

      # Threshold 1 forces promotion: every real chunk offset exceeds it.
      fixed = ISOMedia.Offsets.fix_chunk_offsets(synth, co64_threshold: 1)
      assert ISOMedia.Box.find(fixed, ~w(moov trak mdia minf stbl co64)) != nil

      out = ISOMedia.serialize(fixed)
      # Zip by sample index (robust even when several samples share a size); the bytes
      # are unchanged content, only their absolute offsets move with the larger co64 table.
      Enum.zip(expected, ISOMedia.samples(fixed, tid))
      |> Enum.each(fn {bytes, s} -> assert :binary.part(out, s.offset, s.size) == bytes end)
    end

    test "fix_chunk_offsets is idempotent after a move" do
      {synth, _tid} = synth_track()
      moved = List.insert_at(synth, 2, %Box{type: "free", data: <<0, 0, 0, 0>>})
      once = ISOMedia.fix_chunk_offsets(moved)
      twice = ISOMedia.fix_chunk_offsets(once)
      assert ISOMedia.serialize(twice) == ISOMedia.serialize(once)
    end

    test "still raises when a stamped mdat's size no longer matches its basis" do
      {synth, _tid} = synth_track()
      # Prepend a byte to the mdat segment list: box_size now != stamped source_size.
      grown =
        Enum.map(synth, fn b ->
          if b.type == "mdat", do: %{b | data: [<<0>> | b.data]}, else: b
        end)

      assert_raise ArgumentError, fn -> ISOMedia.fix_chunk_offsets(grown) end
    end
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `mix test test/iso_media/offsets_test.exs`
Expected: PASS (all tests).

- [ ] **Step 3: Verify the pre-existing stampless guard test still passes**

The test `"raises when an mdat was synthesized (no source_offset)"` (offsets_test.exs:85) builds a **hand-built, stamp-less** `%Box{type: "mdat", data: <<1>>}` — which must still raise (we only stamp via `synthesized_mdat/3`). Confirm it is unchanged and green.

Run: `mix test test/iso_media/offsets_test.exs:85`
Expected: PASS (unchanged behavior).

- [ ] **Step 4: Commit**

```bash
git add test/iso_media/offsets_test.exs
git commit -m "test: co64 promotion, idempotence, and size-guard coverage for synthesized mdats"
```

---

### Task 4: Documentation

**Files:**
- Modify: `lib/iso_media.ex` (moduledoc), `docs/ROADMAP.md`, `CLAUDE.md`

- [ ] **Step 1: Update the `ISOMedia` moduledoc**

In `lib/iso_media.ex`, replace this moduledoc passage:

```elixir
  `trim`, `extract_track`, `concat`, `fragment`, and `defragment` outputs can be chained
  in memory (no disk round-trip); `faststart/1`/`fix_chunk_offsets/1` require an original
  parsed `mdat` and raise on a synthesized one.
```

with:

```elixir
  `trim`, `extract_track`, `concat`, `fragment`, and `defragment` outputs can be chained
  in memory (no disk round-trip), including through `faststart/1`/`fix_chunk_offsets/1`,
  which also handle synthesized (segment-list) `mdat`s — a no-op when the `mdat` has not
  moved, a uniform chunk-offset remap when it has.
```

- [ ] **Step 2: Update `docs/ROADMAP.md`**

In `docs/ROADMAP.md`, find the "Sample-table / editing gaps" section and replace its
`**Sample-level offset editing** (offsets.ex:79)` bullet with a note that *relocation* of a
synthesized `mdat` now works, leaving only true payload reordering/resizing deferred:

```markdown
- **Sample-level offset editing** (`offsets.ex`) — chunk-offset *relocation* of a synthesized
  (segment-list) `mdat` now works in memory (`fix_chunk_offsets`/`faststart` no longer raise on
  synthesized trees; see `MdatSource.synthesized_mdat/3`). Still deferred: recomputing offsets
  from `stsc`/`stsz` for genuine payload *reordering/resizing* (a size change still raises).
```

- [ ] **Step 3: Update `CLAUDE.md`**

In `CLAUDE.md`, in the `ISOMedia.MdatSource` module-map entry, append one sentence:

```markdown
Also exposes `synthesized_mdat/3`, which builds a segment-list `mdat` and stamps
`source_offset`/`source_size` (the basis its baked chunk offsets assume) so `Offsets` can
remap it after a move — used by `ProgressiveBuild`/`Trim`/`Extract`.
```

And in the `ISOMedia.Offsets` entry, append:

```markdown
Because synthesized `mdat`s now carry a stamped basis (`MdatSource.synthesized_mdat/3`),
`fix_chunk_offsets/1` and `faststart/1` work on `trim`/`concat`/`extract`/`defragment` output
in memory (no disk round-trip): a no-op when unmoved, a uniform per-`mdat` delta when relocated.
```

- [ ] **Step 4: Verify compilation (docs don't break the build) and commit**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings.

```bash
git add lib/iso_media.ex docs/ROADMAP.md CLAUDE.md
git commit -m "docs: record in-memory offset fixing for synthesized mdats"
```

---

### Task 5: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Format check**

Run: `mix format --check-formatted`
Expected: no output, exit 0. (If it fails, run `mix format` and amend the relevant commit.)

- [ ] **Step 2: Full test suite**

Run: `mix test`
Expected: PASS — all tests and properties green, 0 failures. (The swap does not change serialized bytes — `source_offset`/`source_size` are never serialized — so every existing round-trip/property test is unaffected.)

- [ ] **Step 3: Warnings-as-errors compile**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 4: Confirm `offsets.ex` was never modified**

Run: `git diff --name-only main..HEAD -- lib/iso_media/offsets.ex`
Expected: empty output (the offset engine is unchanged by design — the core promise of this feature).
