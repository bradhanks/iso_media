# CMAF Segment Emission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ISOMedia.split_segments/1` splits a fragmented tree into `%{init: [ftyp, moov], segments: [[styp, moof, mdat], …]}`, and `ISOMedia.write_segments/3` writes them as `init.mp4` + `seg-N.m4s` files — the DASH/CMAF on-disk layout, lossless and memory-safe.

**Architecture:** Pure container surgery on `fragment/2` output: take the boxes before the first `moof` as the init segment, pair each `moof` with its following `mdat` into a media segment prefixed by a `styp` (copied from `ftyp`). No offset recomputation (Phase 10 emits `default-base-is-moof`, so fragments are position-independent). `write_segments/3` loops the existing memory-safe `write/2`. Correctness anchored by reversibility: `init ++ (segments minus styp)` serializes byte-identically to the original.

**Tech Stack:** Elixir, ExUnit. Reuses Phase 10's `sample_keyint.mp4` fixture. No new deps.

---

## File structure

**Created:**
- `lib/iso_media/segment.ex` — `split/1`, `write_segments/3`, private `styp/1`
- `test/iso_media/segment_test.exs` — split correctness + file emit

**Modified:**
- `lib/iso_media.ex` — `split_segments/1` and `write_segments/3` delegators
- `CLAUDE.md` — architecture bullet

`Box.t()` fields: `type, data, children, uuid, size_mode, source_offset, source_size`.
`ISOMedia.write(path, boxes)` returns `:ok | {:error, reason}` and closes its file handle per
call (the segment loop is FD-safe for free). `fragment/2` output is `[ftyp, moov, (moof, mdat)+]`.

---

## Task 1: `Segment.split/1` (pure split + correctness)

**Files:**
- Create: `lib/iso_media/segment.ex`
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media/segment_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/segment_test.exs`:

```elixir
defmodule ISOMedia.SegmentTest do
  use ExUnit.Case
  alias ISOMedia.Box

  @keyint "test/fixtures/sample_keyint.mp4"

  defp fragged do
    {:ok, b} = ISOMedia.read(@keyint)
    ISOMedia.fragment(b, target_duration: 0.3)
  end

  defp sample_bytes(boxes, samples) do
    recs = ISOMedia.MdatSource.collect(boxes)

    samples
    |> Enum.map(fn smp ->
      seg = ISOMedia.MdatSource.segment(recs, smp.offset, smp.size)
      ISOMedia.Box.read_data(%Box{type: "x", data: List.wrap(seg)})
    end)
    |> IO.iodata_to_binary()
  end

  describe "split_segments/1" do
    test "init is [ftyp, moov] and each segment is [styp, moof, mdat]" do
      frag = fragged()
      moof_count = Enum.count(frag, &(&1.type == "moof"))
      %{init: init, segments: segments} = ISOMedia.split_segments(frag)

      assert Enum.map(init, & &1.type) == ["ftyp", "moov"]
      assert length(segments) == moof_count
      assert moof_count >= 2

      for seg <- segments do
        assert Enum.map(seg, & &1.type) == ["styp", "moof", "mdat"]
      end
    end

    test "styp copies the ftyp brands" do
      frag = fragged()
      ftyp = Enum.find(frag, &(&1.type == "ftyp"))
      %{segments: [[styp | _] | _]} = ISOMedia.split_segments(frag)
      assert styp.type == "styp"
      assert styp.data == ftyp.data
    end

    test "split is losslessly reversible (init ++ segments minus styp == original)" do
      frag = fragged()
      %{init: init, segments: segments} = ISOMedia.split_segments(frag)
      reassembled = init ++ Enum.flat_map(segments, fn [_styp, moof, mdat] -> [moof, mdat] end)
      assert ISOMedia.serialize(reassembled) == ISOMedia.serialize(frag)
    end

    test "init ++ one segment is a self-contained fragmented file whose samples resolve" do
      frag = fragged()
      %{init: init, segments: [seg1 | _]} = ISOMedia.split_segments(frag)
      standalone = init ++ seg1

      assert ISOMedia.FragmentIndex.fragmented?(standalone)
      [tid | _] = ISOMedia.track_ids(standalone)
      seg_samples = ISOMedia.samples(standalone, tid)
      frag_samples = ISOMedia.samples(frag, tid) |> Enum.take(length(seg_samples))

      assert seg_samples != []
      assert Enum.map(seg_samples, & &1.size) == Enum.map(frag_samples, & &1.size)
      assert Enum.map(seg_samples, & &1.dts) == Enum.map(frag_samples, & &1.dts)
      assert sample_bytes(standalone, seg_samples) == sample_bytes(frag, frag_samples)
    end

    test "raises on progressive input, missing ftyp/moov, or an orphan moof" do
      {:ok, prog} = ISOMedia.read(@keyint)
      assert_raise ArgumentError, fn -> ISOMedia.split_segments(prog) end

      no_ftyp = [%Box{type: "moov"}, %Box{type: "moof"}, %Box{type: "mdat", data: <<>>}]
      assert_raise ArgumentError, fn -> ISOMedia.split_segments(no_ftyp) end

      orphan = [
        %Box{type: "ftyp", data: <<"isom", 0::32>>},
        %Box{type: "moov"},
        %Box{type: "moof"},
        %Box{type: "moof"}
      ]

      assert_raise ArgumentError, fn -> ISOMedia.split_segments(orphan) end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/segment_test.exs`
Expected: FAIL — `ISOMedia.split_segments/1` undefined.

- [ ] **Step 3: Create `ISOMedia.Segment` and the delegator**

Create `lib/iso_media/segment.ex`:

```elixir
defmodule ISOMedia.Segment do
  @moduledoc """
  Split a fragmented MP4 tree (the output of `ISOMedia.fragment/2`, shape
  `[ftyp, moov, (moof, mdat)+]`) into the DASH/CMAF on-disk layout: a media-less init
  segment (`[ftyp, moov]`) plus N standalone media segments (`[styp, moof, mdat]`).

  Lossless and memory-safe — each segment's `mdat` stays a source-referencing segment
  list, so `write_segments/3` streams each segment file disk→disk. The split is
  structure-preserving: a muxed input yields muxed segments. For single-track segments,
  compose `extract_track |> fragment |> split` per track.
  """
  alias ISOMedia.Box

  @doc """
  Split a fragmented tree into `%{init: [ftyp, moov], segments: [[styp, moof, mdat], …]}`.
  Raises `ArgumentError` unless the input is `[ftyp, moov, (moof, mdat)+]`.
  """
  @spec split([Box.t()]) :: %{init: [Box.t()], segments: [[Box.t()]]}
  def split([%Box{type: "ftyp"} = ftyp, %Box{type: "moov"} = moov | rest]) do
    %{init: [ftyp, moov], segments: pair_fragments(rest, styp(ftyp), [])}
  end

  def split(_boxes) do
    raise ArgumentError, "split_segments: expected a fragmented tree [ftyp, moov, (moof, mdat)+]"
  end

  defp pair_fragments([], _styp, []) do
    raise ArgumentError, "split_segments: no moof/mdat fragments (input is not fragmented)"
  end

  defp pair_fragments([], _styp, acc), do: Enum.reverse(acc)

  defp pair_fragments([%Box{type: "moof"} = moof, %Box{type: "mdat"} = mdat | rest], styp, acc) do
    pair_fragments(rest, styp, [[styp, moof, mdat] | acc])
  end

  defp pair_fragments([%Box{type: "moof"} | _], _styp, _acc) do
    raise ArgumentError, "split_segments: a moof is not followed by an mdat"
  end

  defp pair_fragments([%Box{type: t} | _], _styp, _acc) do
    raise ArgumentError, "split_segments: expected moof/mdat fragments, got #{t}"
  end

  defp styp(%Box{type: "ftyp"} = ftyp) do
    %Box{type: "styp", data: ftyp.data, size_mode: ftyp.size_mode}
  end
end
```

In `lib/iso_media.ex`, add after the `fragment/2` delegator:

```elixir
  @doc "Split a fragmented tree into a CMAF init segment + media segments. See `ISOMedia.Segment.split/1`."
  @spec split_segments(tree()) :: %{init: tree(), segments: [tree()]}
  def split_segments(boxes), do: ISOMedia.Segment.split(boxes)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/segment_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/segment.ex lib/iso_media.ex test/iso_media/segment_test.exs
git commit -m "feat: ISOMedia.split_segments/1 (fragmented tree -> init + CMAF segments)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `Segment.write_segments/3` (file emit) + docs

**Files:**
- Modify: `lib/iso_media/segment.ex`, `lib/iso_media.ex`, `CLAUDE.md`
- Test: `test/iso_media/segment_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/iso_media/segment_test.exs` (after the `split_segments/1`
describe block):

```elixir
  describe "write_segments/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "iso_seg_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "writes init.mp4 + seg-N.m4s; reassembling them equals the original", %{dir: dir} do
      frag = fragged()
      n = Enum.count(frag, &(&1.type == "moof"))

      assert {:ok, paths} = ISOMedia.write_segments(dir, frag)
      assert hd(paths) == Path.join(dir, "init.mp4")
      assert length(paths) == n + 1
      assert Enum.all?(paths, &File.exists?/1)

      {:ok, init} = ISOMedia.read(Path.join(dir, "init.mp4"))

      seg_boxes =
        for i <- 1..n do
          {:ok, [_styp, moof, mdat]} = ISOMedia.read(Path.join(dir, "seg-#{i}.m4s"))
          [moof, mdat]
        end

      reassembled = init ++ List.flatten(seg_boxes)
      assert ISOMedia.serialize(reassembled) == ISOMedia.serialize(frag)
    end

    test "creates the directory if absent and honors a custom segment_pattern", %{dir: dir} do
      frag = fragged()
      sub = Path.join(dir, "nested/segs")
      pattern = fn i -> "chunk_#{i}.m4s" end

      assert {:ok, paths} = ISOMedia.write_segments(sub, frag, segment_pattern: pattern)
      assert File.dir?(sub)
      assert Enum.at(paths, 1) == Path.join(sub, "chunk_1.m4s")
      assert File.exists?(Path.join(sub, "chunk_1.m4s"))
    end

    test "lazy and eager produce byte-identical segment files", %{dir: dir} do
      {:ok, prog_eager} = ISOMedia.read(@keyint)
      frag_eager = ISOMedia.fragment(prog_eager, target_duration: 0.3)

      {:ok, prog_lazy} = ISOMedia.read(@keyint, lazy: true)
      frag_lazy = ISOMedia.fragment(prog_lazy, target_duration: 0.3)

      eager_dir = Path.join(dir, "eager")
      lazy_dir = Path.join(dir, "lazy")
      {:ok, _} = ISOMedia.write_segments(eager_dir, frag_eager)
      {:ok, _} = ISOMedia.write_segments(lazy_dir, frag_lazy)

      assert File.read!(Path.join(eager_dir, "seg-1.m4s")) ==
               File.read!(Path.join(lazy_dir, "seg-1.m4s"))

      assert File.read!(Path.join(eager_dir, "init.mp4")) ==
               File.read!(Path.join(lazy_dir, "init.mp4"))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/segment_test.exs`
Expected: FAIL — `ISOMedia.write_segments/3` undefined.

- [ ] **Step 3: Implement `write_segments/3` + delegator**

In `lib/iso_media/segment.ex`, add after `split/1` (the `alias ISOMedia.Box` already present):

```elixir
  @doc """
  Split `boxes` and write the init + media segments into `dir` (created if absent):
  `init.mp4` and `seg-1.m4s, seg-2.m4s, …`. `opts[:init_name]` overrides the init filename;
  `opts[:segment_pattern]` is a `fn index -> filename end` (default `fn i -> "seg-\#{i}.m4s" end`).
  Returns `{:ok, paths}` (init first, then segments in order) or the first `write/2`
  `{:error, reason}`. Each segment streams disk→disk; the file handle is closed per segment.
  """
  @spec write_segments(Path.t(), [Box.t()], keyword()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def write_segments(dir, boxes, opts \\ []) do
    %{init: init, segments: segments} = split(boxes)
    File.mkdir_p!(dir)

    init_name = Keyword.get(opts, :init_name, "init.mp4")
    pattern = Keyword.get(opts, :segment_pattern, fn i -> "seg-#{i}.m4s" end)
    init_path = Path.join(dir, init_name)

    case ISOMedia.write(init_path, init) do
      :ok -> write_each(segments, dir, pattern, 1, [init_path])
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_each([], _dir, _pattern, _i, acc), do: {:ok, Enum.reverse(acc)}

  defp write_each([seg | rest], dir, pattern, i, acc) do
    path = Path.join(dir, pattern.(i))

    case ISOMedia.write(path, seg) do
      :ok -> write_each(rest, dir, pattern, i + 1, [path | acc])
      {:error, reason} -> {:error, reason}
    end
  end
```

In `lib/iso_media.ex`, add after the `split_segments/1` delegator:

```elixir
  @doc "Write a fragmented tree's init + media segment files into `dir`. See `ISOMedia.Segment.write_segments/3`."
  @spec write_segments(Path.t(), tree(), keyword()) :: {:ok, [Path.t()]} | {:error, term()}
  def write_segments(dir, boxes, opts \\ []), do: ISOMedia.Segment.write_segments(dir, boxes, opts)
```

- [ ] **Step 4: Run test + full sweep**

Run: `mix test test/iso_media/segment_test.exs && mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: segment tests pass; full suite 0 failures; format clean; no warnings.

- [ ] **Step 5: Update CLAUDE.md and commit**

In `CLAUDE.md`, add an `ISOMedia.Segment` bullet to the architecture list (near `Fragment`):
`split/1` splits a `fragment/2`-shaped tree into `%{init: [ftyp, moov], segments: [[styp, moof, mdat]]}` (CMAF on-disk layout; `styp` copied from `ftyp`; no offset surgery thanks to default-base-is-moof); `write_segments/3` writes `init.mp4` + `seg-N.m4s` via `write/2`, streaming disk→disk. Exposed as `ISOMedia.split_segments/1` and `ISOMedia.write_segments/3`.

```bash
git add lib/iso_media/segment.ex lib/iso_media.ex test/iso_media/segment_test.exs CLAUDE.md
git commit -m "feat: ISOMedia.write_segments/3 (write CMAF init + media segment files)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Full guarantee sweep**

Run: `mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: 0 failures, format clean, no warnings.

---

## Spec coverage check

- `split/1` → `%{init, segments}`, structure-preserving, `styp` from `ftyp`, no offset surgery → Task 1.
- Strict input contract (raise on progressive / missing ftyp-moov / orphan moof) → Task 1.
- Reversibility correctness anchor → Task 1.
- Self-contained/playable segment (samples resolve) → Task 1.
- `write_segments/3` (mkdir_p, init.mp4 + seg-N.m4s, `segment_pattern` fn, returns paths, disk→disk) → Task 2.
- lazy == eager → Task 2.
- `split_segments/1` + `write_segments/3` public delegators → Tasks 1, 2.
- Deferred (manifests, sidx, demuxed-as-builtin, arbitrary-fMP4 robustness, CMAF brand sets) → not implemented, by design.
```
