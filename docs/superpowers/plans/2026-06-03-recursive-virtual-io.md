# Recursive Virtual I/O Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `trim`/`concat`/`extract_track` outputs feed one another entirely in memory by making segment lists recursive and teaching `MdatSource` to resolve byte ranges through nested segment trees — no disk round-trip between pipeline stages.

**Architecture:** A leaf's `data` becomes a recursive type `binary | FileSlice | [segment]` where `segment :: binary | FileSlice | [segment]`. `MdatSource.collect/1` captures each `mdat`'s absolute `payload_start`/`payload_size` from a single `Layout` walk (the one source of truth for offsets), and `segment/3` resolves a range as `relative = offset − payload_start`, slicing binaries/FileSlices directly and recursing into nested segment lists. `Layout.box_size`, `Serializer.materialize`/`stream`, and the `collect_slice_paths` overwrite guard each gain one nested-list recursion arm. All three resolver callers (`Extract`, `Trim`, `Concat`) are unified onto the `collect/1 → segment/3` contract.

**Tech Stack:** Elixir, ExUnit, binary pattern matching. No new dependencies.

---

## File structure

**Modified:**
- `lib/iso_media/layout.ex` — add `segment_size/1` + `segments_size/1` (recursive), route `box_size` list clause through them.
- `lib/iso_media/mdat_source.ex` — rewrite `collect/1` (returns records) and `segment/3` (record contract, relative math, recursive segment-list resolution); remove the segment-list raise.
- `lib/iso_media/extract.ex` — line 48: `Enum.filter` → `MdatSource.collect/1`.
- `lib/iso_media/serializer.ex` — `materialize_box/1` and `stream_payload/1` list clauses recurse into nested lists.
- `lib/iso_media.ex` — `collect_slice_paths/1` list clause recurses into nested lists.

**Tests modified/created:**
- `test/iso_media/layout_test.exs` — nested segment-list sizing.
- `test/iso_media/mdat_source_test.exs` — rewritten for the `collect/1 → segment/3` record contract + nested resolution.
- `test/iso_media/serializer_test.exs` — nested segment-list serialize/stream.
- `test/iso_media/recursive_io_test.exs` — **new**, the headline chaining proof + overwrite guard + lazy==eager.

**Contract change (record shape).** `MdatSource.collect/1` returns `[%{box: %Box{}, payload_start: non_neg_integer, payload_size: non_neg_integer}]` (was `[%Box{}]`). `MdatSource.segment(records, offset, length)` keeps its arity; only the element type of the first arg changes.

---

## Task 1: `Layout` recursive segment sizing

**Files:**
- Modify: `lib/iso_media/layout.ex:23-34`
- Test: `test/iso_media/layout_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/layout_test.exs`:

```elixir
alias ISOMedia.{Box, FileSlice, Layout}

test "box_size sums a nested segment list recursively" do
  # data is [binary, [binary, FileSlice]] — a 1-level-nested segment list
  box = %Box{
    type: "mdat",
    size_mode: :compact,
    data: [<<1, 2, 3>>, [<<4, 5>>, %FileSlice{path: "x", offset: 0, length: 10}]]
  }

  # header 8 + (3 + (2 + 10)) = 8 + 15 = 23
  assert Layout.box_size(box) == 23
end

test "segments_size/1 sums binary, FileSlice and nested-list parts" do
  parts = [<<0, 0>>, %FileSlice{path: "x", offset: 0, length: 4}, [<<0>>, <<0, 0, 0>>]]
  assert Layout.segments_size(parts) == 2 + 4 + 4
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/layout_test.exs`
Expected: FAIL — `Layout.segments_size/1` undefined and `box_size` raises/crashes on the nested list element.

- [ ] **Step 3: Write minimal implementation**

In `lib/iso_media/layout.ex`, replace the list `box_size` clause (currently lines 26-34) and add the helpers:

```elixir
def box_size(%Box{data: %FileSlice{length: len}} = box), do: header_size(box) + len

def box_size(%Box{data: parts} = box) when is_list(parts) do
  header_size(box) + segments_size(parts)
end

def box_size(%Box{data: nil, children: children} = box) do
  header_size(box) + Enum.sum(Enum.map(children, &box_size/1))
end

def box_size(%Box{data: data} = box) do
  header_size(box) + byte_size(data)
end

@doc "Total byte length of a (possibly nested) segment list's parts."
def segments_size(parts) when is_list(parts), do: Enum.sum(Enum.map(parts, &segment_size/1))

@doc "Byte length of one segment part: a binary, a FileSlice, or a nested segment list."
def segment_size(%FileSlice{length: len}), do: len
def segment_size(bin) when is_binary(bin), do: byte_size(bin)
def segment_size(parts) when is_list(parts), do: segments_size(parts)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/layout_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/layout.ex test/iso_media/layout_test.exs
git commit -m "feat: Layout sizes nested segment lists (segment_size/segments_size)"
```

---

## Task 2: `MdatSource.collect/1` returns layout-captured records

**Files:**
- Modify: `lib/iso_media/mdat_source.ex:10-11`
- Test: `test/iso_media/mdat_source_test.exs`

- [ ] **Step 1: Write the failing test**

Replace the body of `test/iso_media/mdat_source_test.exs` with (we rebuild this file across Tasks 2-4):

```elixir
defmodule ISOMedia.MdatSourceTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FileSlice, MdatSource}

  describe "collect/1" do
    test "captures payload_start/payload_size from the layout walk" do
      ftyp = %Box{type: "ftyp", size_mode: :compact, data: <<0, 0, 0, 0>>}
      mdat = %Box{type: "mdat", size_mode: :compact, data: <<0, 1, 2, 3, 4, 5, 6, 7>>}

      # ftyp: 8 header + 4 payload = 12. mdat starts at 12, payload at 12+8 = 20.
      assert [%{box: ^mdat, payload_start: 20, payload_size: 8}] =
               MdatSource.collect([ftyp, mdat])
    end

    test "captures multiple mdats in order" do
      a = %Box{type: "mdat", size_mode: :compact, data: <<0, 0, 0, 0>>}
      free = %Box{type: "free", size_mode: :compact, data: <<0, 0>>}
      b = %Box{type: "mdat", size_mode: :compact, data: <<9, 9, 9>>}

      # a: 12 bytes (payload at 8). free: 10 bytes (starts at 12). b: starts at 22, payload at 30.
      assert [%{payload_start: 8, payload_size: 4}, %{payload_start: 30, payload_size: 3}] =
               MdatSource.collect([a, free, b])
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/mdat_source_test.exs`
Expected: FAIL — `collect/1` returns `[%Box{}]`, not the record maps.

- [ ] **Step 3: Write minimal implementation**

In `lib/iso_media/mdat_source.ex`, replace `collect/1` (lines 10-11). Keep the `alias` line including `Layout`:

```elixir
@doc """
Capture each top-level `mdat`'s absolute payload range from a single `Layout` walk:
`[%{box: mdat, payload_start: abs, payload_size: len}]`. The walk uses the same
`Layout.box_size/1` the serializer uses, so the offsets are byte-identical to the
written file — the basis for drift-free recursive resolution.
"""
def collect(boxes) do
  {records, _end_off} =
    Enum.flat_map_reduce(boxes, 0, fn box, off ->
      size = Layout.box_size(box)

      records =
        if box.type == "mdat" do
          header = Layout.header_size(box)
          [%{box: box, payload_start: off + header, payload_size: size - header}]
        else
          []
        end

      {records, off + size}
    end)

  records
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/mdat_source_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/mdat_source.ex test/iso_media/mdat_source_test.exs
git commit -m "feat: MdatSource.collect/1 captures layout-driven mdat payload offsets"
```

---

## Task 3: `MdatSource.segment/3` — record contract + leaf resolution

**Files:**
- Modify: `lib/iso_media/mdat_source.ex:13-32`
- Test: `test/iso_media/mdat_source_test.exs`

- [ ] **Step 1: Write the failing test**

Add a `describe "segment/3 leaves"` block to `test/iso_media/mdat_source_test.exs`:

```elixir
  describe "segment/3 leaves" do
    test "binary mdat returns a binary_part at the relative offset" do
      mdat = %Box{type: "mdat", size_mode: :compact, data: for(i <- 0..15, into: <<>>, do: <<i>>)}
      [rec] = MdatSource.collect([mdat])
      # payload_start is 8; absolute offset 8 == relative 0
      assert MdatSource.segment([rec], 8, 4) == <<0, 1, 2, 3>>
      assert MdatSource.segment([rec], 10, 2) == <<2, 3>>
    end

    test "FileSlice mdat resolves fs.offset + relative (decoupled from absolute target)" do
      # The mdat payload lives on disk starting at byte 1000, even though in this tree
      # its captured payload_start is 8. Resolution must use fs.offset + relative = 1000 + 2.
      mdat = %Box{
        type: "mdat",
        size_mode: :compact,
        data: %FileSlice{path: "src", offset: 1000, length: 16}
      }

      [rec] = MdatSource.collect([mdat])
      assert MdatSource.segment([rec], 10, 3) == %FileSlice{path: "src", offset: 1002, length: 3}
    end

    test "raises when offset falls outside every mdat" do
      mdat = %Box{type: "mdat", size_mode: :compact, data: <<0, 1, 2, 3>>}
      recs = MdatSource.collect([mdat])
      assert_raise ArgumentError, fn -> MdatSource.segment(recs, 9999, 2) end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/mdat_source_test.exs`
Expected: FAIL — `segment/3` still expects `%Box{}` with `source_offset`, crashes on record maps.

- [ ] **Step 3: Write minimal implementation**

In `lib/iso_media/mdat_source.ex`, replace `segment/3` (lines 13-32) with the record-based resolver. (Recursive segment-list resolution is added in Task 4; here a list payload falls through to a temporary raise so this task stays minimal.)

```elixir
@doc """
Resolve the absolute `offset`..`offset+length` range to a payload segment, given the
records from `collect/1`. Returns a `binary`, a `%FileSlice{}`, or (for a segment-list
mdat) a nested segment list. Uses `relative = offset - payload_start`, so a physical
`FileSlice` acts as a local byte provider (`fs.offset + relative`) independent of the
absolute target.
"""
def segment(records, offset, length) do
  rec =
    Enum.find(records, fn r ->
      offset >= r.payload_start and offset < r.payload_start + r.payload_size
    end) || raise ArgumentError, "byte range at offset #{offset} falls outside every mdat"

  resolve(rec.box.data, offset - rec.payload_start, length)
end

defp resolve(%FileSlice{path: path, offset: base}, relative, length) do
  %FileSlice{path: path, offset: base + relative, length: length}
end

defp resolve(bin, relative, length) when is_binary(bin) do
  binary_part(bin, relative, length)
end

defp resolve(parts, _relative, _length) when is_list(parts) do
  raise ArgumentError, "segment-list resolution not yet implemented"
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/mdat_source_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/mdat_source.ex test/iso_media/mdat_source_test.exs
git commit -m "feat: MdatSource.segment/3 resolves binary/FileSlice via relative offset math"
```

---

## Task 4: `MdatSource.segment/3` — recursive segment-list resolution

**Files:**
- Modify: `lib/iso_media/mdat_source.ex` (replace the temporary `resolve/3` list clause)
- Test: `test/iso_media/mdat_source_test.exs`

- [ ] **Step 1: Write the failing test**

Add a `describe "segment/3 segment lists"` block to `test/iso_media/mdat_source_test.exs`:

```elixir
  describe "segment/3 segment lists" do
    defp seglist_mdat(parts) do
      mdat = %Box{type: "mdat", size_mode: :compact, data: parts}
      MdatSource.collect([mdat])
    end

    test "range within a single part returns that part's slice (bare, not wrapped)" do
      recs = seglist_mdat([<<0, 1, 2, 3>>, <<4, 5, 6, 7>>])
      # payload_start 8. Absolute 9 -> relative 1, within part 0.
      assert MdatSource.segment(recs, 9, 2) == <<1, 2>>
    end

    test "range spanning two parts returns a list of the two slices" do
      recs = seglist_mdat([<<0, 1, 2, 3>>, <<4, 5, 6, 7>>])
      # relative 2..6 -> [<<2,3>>, <<4,5>>]
      assert MdatSource.segment(recs, 10, 4) == [<<2, 3>>, <<4, 5>>]
    end

    test "slices a FileSlice part by adding the in-part start to fs.offset" do
      recs = seglist_mdat([<<0, 1>>, %FileSlice{path: "x", offset: 500, length: 6}])
      # relative 3 -> part 1, in-part start 1 -> fs.offset 500+1, length 4
      assert MdatSource.segment(recs, 11, 4) == %FileSlice{path: "x", offset: 501, length: 4}
    end

    test "recurses through a nested segment list, preserving nesting in the result" do
      # parts: [<<0,1>>, [<<2,3>>, %FileSlice{...len 4}]] — total payload 8 bytes
      nested = [<<2, 3>>, %FileSlice{path: "y", offset: 0, length: 4}]
      recs = seglist_mdat([<<0, 1>>, nested])
      # relative 1..8 (7 bytes) -> part0 tail <<1>>, then into nested: <<2,3>> + fs[0,4]
      assert MdatSource.segment(recs, 9, 7) ==
               [<<1>>, [<<2, 3>>, %FileSlice{path: "y", offset: 0, length: 4}]]
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/mdat_source_test.exs`
Expected: FAIL — the temporary list clause raises "segment-list resolution not yet implemented".

- [ ] **Step 3: Write minimal implementation**

In `lib/iso_media/mdat_source.ex`, replace the temporary list `resolve/3` clause with the real recursive resolver. Add `alias ISOMedia.Layout` usage (already aliased):

```elixir
defp resolve(parts, relative, length) when is_list(parts) do
  resolve_in_segments(parts, relative, length)
end

# Walk parts accumulating their byte lengths; slice each part overlapping
# [lo, lo+len). One overlapping part -> return its slice bare; several -> a list.
defp resolve_in_segments(parts, lo, len) do
  hi = lo + len

  {slices, _pos} =
    Enum.flat_map_reduce(parts, 0, fn part, pos ->
      part_len = Layout.segment_size(part)
      part_hi = pos + part_len

      if part_hi <= lo or pos >= hi do
        {[], part_hi}
      else
        start = max(lo, pos) - pos
        take = min(hi, part_hi) - max(lo, pos)
        {[slice_part(part, start, take)], part_hi}
      end
    end)

  case slices do
    [one] -> one
    many -> many
  end
end

defp slice_part(%FileSlice{path: p, offset: o}, start, take) do
  %FileSlice{path: p, offset: o + start, length: take}
end

defp slice_part(bin, start, take) when is_binary(bin) do
  binary_part(bin, start, take)
end

defp slice_part(parts, start, take) when is_list(parts) do
  resolve_in_segments(parts, start, take)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/mdat_source_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/mdat_source.ex test/iso_media/mdat_source_test.exs
git commit -m "feat: MdatSource resolves nested segment lists recursively"
```

---

## Task 5: Unify `Extract` onto `collect/1`, prove no regression

**Files:**
- Modify: `lib/iso_media/extract.ex:48`
- Test: existing `test/iso_media/extract_test.exs`, `extract_av_test.exs`, `trim_*`, `concat_*` suites

- [ ] **Step 1: Run the suites to confirm current green baseline**

Run: `mix test test/iso_media/extract_test.exs test/iso_media/extract_av_test.exs test/iso_media/trim_test.exs test/iso_media/concat_test.exs`
Expected: PASS (baseline before the edit).

- [ ] **Step 2: Make the edit**

In `lib/iso_media/extract.ex`, replace line 48:

```elixir
    mdats = Enum.filter(boxes, &(&1.type == "mdat"))
```

with:

```elixir
    mdats = MdatSource.collect(boxes)
```

(`MdatSource` is already aliased at extract.ex:9. The `segment(mdats, off, len)` call at line 58 now receives records, matching the new contract.)

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS — `Extract`, `Trim`, and `Concat` all drive the resolver through `collect/1 → segment/3`. Non-chained extraction/trim/concat behavior is unchanged because `collect/1` reproduces parsed files' on-disk offsets (byte-exact invariant).

- [ ] **Step 4: Commit**

```bash
git add lib/iso_media/extract.ex
git commit -m "refactor: Extract uses MdatSource.collect/1 (unified resolver contract)"
```

---

## Task 6: `Serializer` recurses through nested segment lists

**Files:**
- Modify: `lib/iso_media/serializer.ex:18-28` (materialize) and `:110-115` (stream)
- Test: `test/iso_media/serializer_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/serializer_test.exs`:

```elixir
alias ISOMedia.{Box, FileSlice, Serializer}

test "serialize materializes a nested segment list in order" do
  # write a temp file so the FileSlice has real bytes
  path = Path.join(System.tmp_dir!(), "ser_nested_#{System.unique_integer([:positive])}.bin")
  File.write!(path, <<10, 11, 12, 13>>)
  on_exit(fn -> File.rm(path) end)

  box = %Box{
    type: "mdat",
    size_mode: :compact,
    data: [<<0, 1>>, [<<2, 3>>, %FileSlice{path: path, offset: 1, length: 2}]]
  }

  # header(8) + payload <<0,1,2,3, 11,12>>
  assert Serializer.serialize(box) == <<14::32, "mdat", 0, 1, 2, 3, 11, 12>>
end

test "stream writes a nested segment list identically to serialize" do
  path = Path.join(System.tmp_dir!(), "ser_stream_#{System.unique_integer([:positive])}.bin")
  File.write!(path, <<10, 11, 12, 13>>)
  out = Path.join(System.tmp_dir!(), "ser_out_#{System.unique_integer([:positive])}.bin")
  on_exit(fn -> File.rm(path); File.rm(out) end)

  box = %Box{
    type: "mdat",
    size_mode: :compact,
    data: [<<0, 1>>, [<<2, 3>>, %FileSlice{path: path, offset: 1, length: 2}]]
  }

  {:ok, :ok} = File.open(out, [:write, :binary, :raw], fn io -> Serializer.stream(box, io) end)
  assert File.read!(out) == Serializer.serialize(box)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: FAIL — the list clauses crash on the nested-list element (no clause matches a list inside `Enum.map`).

- [ ] **Step 3: Write minimal implementation**

In `lib/iso_media/serializer.ex`, replace the `materialize_box/1` list clause (lines 18-28):

```elixir
defp materialize_box(%Box{data: parts} = box) when is_list(parts) do
  %{box | data: flatten_segments(parts)}
end
```

and add a private helper after `materialize_box/1`:

```elixir
defp flatten_segments(parts) do
  parts
  |> Enum.map(fn
    %FileSlice{} = s -> FileSlice.read(s)
    bin when is_binary(bin) -> bin
    nested when is_list(nested) -> flatten_segments(nested)
  end)
  |> IO.iodata_to_binary()
end
```

Then replace the `stream_payload/1` list clause (lines 110-115):

```elixir
defp stream_payload(%Box{data: parts}, io, chunk) when is_list(parts) do
  stream_segments(parts, io, chunk)
end
```

and add a private helper after `stream_payload/1`:

```elixir
defp stream_segments(parts, io, chunk) do
  Enum.each(parts, fn
    %FileSlice{} = s -> FileSlice.stream(s, io, chunk)
    bin when is_binary(bin) -> write!(io, bin)
    nested when is_list(nested) -> stream_segments(nested, io, chunk)
  end)
end
```

(`Layout.box_size/1` from Task 1 already sizes nested lists, so the `body_len` computed in `stream_box/3` at serializer.ex:101 is correct without further change.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/serializer.ex test/iso_media/serializer_test.exs
git commit -m "feat: Serializer materializes/streams nested segment lists recursively"
```

---

## Task 7: Overwrite guard sees nested FileSlice paths

**Files:**
- Modify: `lib/iso_media.ex:108-113`
- Test: `test/iso_media/recursive_io_test.exs` (new file)

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/recursive_io_test.exs`:

```elixir
defmodule ISOMedia.RecursiveIOTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FileSlice}

  test "write/2 refuses to overwrite a source file referenced inside a nested segment list" do
    src = Path.join(System.tmp_dir!(), "rio_src_#{System.unique_integer([:positive])}.bin")
    File.write!(src, <<0, 1, 2, 3>>)
    on_exit(fn -> File.rm(src) end)

    tree = [
      %Box{type: "ftyp", size_mode: :compact, data: <<0, 0, 0, 0>>},
      %Box{
        type: "mdat",
        size_mode: :compact,
        data: [<<9>>, [%FileSlice{path: src, offset: 0, length: 4}]]
      }
    ]

    assert_raise ArgumentError, ~r/same file as a FileSlice source|is also a FileSlice source/, fn ->
      ISOMedia.write(src, tree)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/recursive_io_test.exs`
Expected: FAIL — `collect_slice_paths/1` doesn't descend into the nested list, so the guard misses `src` and attempts the write.

- [ ] **Step 3: Write minimal implementation**

In `lib/iso_media.ex`, replace the `collect_slice_paths/1` list clause (lines 108-113):

```elixir
defp collect_slice_paths(%ISOMedia.Box{data: parts}) when is_list(parts),
  do: slice_paths_in(parts)
```

and add a private helper after the last `collect_slice_paths/1` clause:

```elixir
defp slice_paths_in(parts) do
  Enum.flat_map(parts, fn
    %ISOMedia.FileSlice{path: p} -> [p]
    bin when is_binary(bin) -> []
    nested when is_list(nested) -> slice_paths_in(nested)
  end)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/recursive_io_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media.ex test/iso_media/recursive_io_test.exs
git commit -m "fix: overwrite guard descends into nested segment lists"
```

---

## Task 8: Headline proof — `trim |> concat |> trim` in-memory == disk round-trip

**Files:**
- Test: `test/iso_media/recursive_io_test.exs` (extend)

- [ ] **Step 1: Write the failing test**

Append to `test/iso_media/recursive_io_test.exs`:

```elixir
  @fixture Path.expand("../fixtures/sample_av.mp4", __DIR__)

  defp tmp(name), do: Path.join(System.tmp_dir!(), "rio_#{name}_#{System.unique_integer([:positive])}.mp4")

  test "chained trim |> concat |> trim matches a disk-round-trip pipeline byte-for-byte" do
    {:ok, a} = ISOMedia.read(@fixture)

    # Fully in-memory: nested segment trees, no intermediate disk writes.
    in_memory =
      a
      |> ISOMedia.trim(0.2, 0.8)
      |> then(fn t1 -> ISOMedia.concat([t1, t1]) end)
      |> ISOMedia.trim(0.1, 0.5)
      |> ISOMedia.serialize()

    # Same operations with a write + re-read between every stage.
    f1 = tmp("t1")
    f2 = tmp("c")
    on_exit(fn -> File.rm(f1); File.rm(f2) end)

    :ok = ISOMedia.write(f1, ISOMedia.trim(a, 0.2, 0.8))
    {:ok, t1d} = ISOMedia.read(f1)
    :ok = ISOMedia.write(f2, ISOMedia.concat([t1d, t1d]))
    {:ok, cd} = ISOMedia.read(f2)
    disk = ISOMedia.serialize(ISOMedia.trim(cd, 0.1, 0.5))

    assert in_memory == disk
  end

  test "every sample of the chained output resolves to the same bytes as the disk pipeline" do
    {:ok, a} = ISOMedia.read(@fixture)
    [track | _] = ISOMedia.track_ids(a)

    chained = a |> ISOMedia.trim(0.2, 0.8) |> then(&ISOMedia.concat([&1, &1]))

    f1 = tmp("t1b")
    on_exit(fn -> File.rm(f1) end)
    :ok = ISOMedia.write(f1, ISOMedia.trim(a, 0.2, 0.8))
    {:ok, t1d} = ISOMedia.read(f1)
    disk = ISOMedia.concat([t1d, t1d])

    # Serializing both must yield identical bytes (proves every resolved sample matches).
    assert ISOMedia.serialize(chained) == ISOMedia.serialize(disk)
    assert length(ISOMedia.samples(chained, track)) == length(ISOMedia.samples(disk, track))
  end

  test "lazy-parsed inputs chain to the same bytes as eager inputs" do
    {:ok, eager} = ISOMedia.read(@fixture)
    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true)

    chain = fn boxes ->
      boxes |> ISOMedia.trim(0.2, 0.8) |> then(&ISOMedia.concat([&1, &1])) |> ISOMedia.serialize()
    end

    assert chain.(lazy) == chain.(eager)
  end
```

- [ ] **Step 2: Run test to verify it fails (or passes) and confirm it exercises the path**

Run: `mix test test/iso_media/recursive_io_test.exs`
Expected: These should PASS once Tasks 1-7 are in. If any fail, the failure is the real proof target — debug with `superpowers:systematic-debugging` before proceeding. (If they pass immediately, confirm they are not vacuous: temporarily break `resolve_in_segments` to assert the byte-identity test flips to FAIL, then restore.)

- [ ] **Step 3: Run the full suite + format + warnings**

Run: `mix test && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: All green, format clean, zero warnings.

- [ ] **Step 4: Commit**

```bash
git add test/iso_media/recursive_io_test.exs
git commit -m "test: prove in-memory trim|>concat|>trim equals disk round-trip (recursive I/O)"
```

---

## Final verification

- [ ] **Update CLAUDE.md architecture notes**

In `CLAUDE.md`, update the `MdatSource` bullet to note it now returns layout-captured records and resolves nested segment lists recursively, and update the `Concat`/`Trim` notes to remove the "must be readable files / can't chain" limitation. Commit:

```bash
git add CLAUDE.md
git commit -m "docs: note recursive virtual I/O (in-memory pipeline chaining)"
```

- [ ] **Full guarantee sweep**

Run: `mix test && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: 0 failures, format clean, no warnings. The byte-for-byte invariant now extends to in-memory chained pipelines.

---

## Spec coverage check

- Recursive segment type `binary | FileSlice | [segment]` → Tasks 1, 4, 6, 7.
- `collect/1` captures offsets from one `Layout` walk → Task 2.
- `segment/3` relative math + FileSlice `fs.offset + relative` → Task 3.
- Recursive segment-list resolution, raise removed → Task 4.
- Unify all three callers on `collect/1 → segment/3` → Tasks 2, 3, 5.
- `Layout.box_size` nested clause + shared sizing helper → Task 1.
- `Serializer.materialize`/`stream` recursion → Task 6.
- `collect_slice_paths` overwrite-guard recursion → Task 7.
- Headline `trim|>concat|>trim` byte-identity + per-sample + lazy==eager → Task 8.
- Deferred (samples seam, packed index, concurrency, network providers) → not implemented, by design.
