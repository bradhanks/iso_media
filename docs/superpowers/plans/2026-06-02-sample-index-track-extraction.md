# Sample Index + Single-Track Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decode a track's sample tables into a flat `[%Sample{}]` index, and extract a single track into its own valid file (rebuilding `mdat` + chunk offsets) — memory-safely, preserving Phase 3's lazy guarantee.

**Architecture:** `ISOMedia.SampleTable.build/1` cross-references `stsz`/`stsc`/`stco`/`co64`/`stts`/`ctts`/`stss` into `[%Sample{}]`. A leaf payload may now be a segment list (`[binary | %FileSlice{}]`), threaded through `Layout`/`Serializer`/`Box`. `ISOMedia.Extract.extract_track/2` groups samples per chunk (`Enum.chunk_by`), builds the new `mdat` as a segment list, and rebuilds `stco`/`co64` with header-size and table-kind decided up front.

**Tech Stack:** Elixir 1.19 / OTP 29, ExUnit, StreamData, ffmpeg (fixtures).

**Branch:** `feat/sample-extract` (holds the approved spec at `docs/superpowers/specs/2026-06-02-sample-index-track-extraction-design.md`).

**Conventions for every commit:** end the message with:
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```
Keep the branch format-clean: run `mix format` and fold it in (a `style: mix format` commit is fine).

---

### Task 1: `ISOMedia.Sample` struct

**Files:**
- Create: `lib/iso_media/sample.ex`
- Test: `test/iso_media/sample_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/sample_test.exs`:

```elixir
defmodule ISOMedia.SampleTest do
  use ExUnit.Case
  alias ISOMedia.Sample

  test "has the expected fields with nil defaults" do
    s = %Sample{}
    assert Map.keys(s) |> Enum.sort() ==
             [:__struct__, :chunk_index, :dts, :index, :offset, :pts, :size, :sync?]
  end

  test "holds sample metadata" do
    s = %Sample{index: 1, chunk_index: 1, dts: 0, pts: 0, size: 10, offset: 1000, sync?: true}
    assert s.index == 1
    assert s.offset == 1000
    assert s.sync?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/sample_test.exs`
Expected: FAIL — `ISOMedia.Sample.__struct__/1 is undefined`.

- [ ] **Step 3: Write the implementation**

Create `lib/iso_media/sample.ex`:

```elixir
defmodule ISOMedia.Sample do
  @moduledoc """
  One media sample, decoded from a track's sample tables.

  `index`/`chunk_index` are 1-based (matching ISOBMFF numbering). `dts`/`pts` are in
  the track's `mdhd` timescale (`pts == dts` when there is no `ctts`). `offset` is the
  sample's absolute byte position in the file. `sync?` is the keyframe flag (true for
  every sample when the track has no `stss`).
  """

  defstruct [:index, :chunk_index, :dts, :pts, :size, :offset, :sync?]

  @type t :: %__MODULE__{
          index: pos_integer(),
          chunk_index: pos_integer(),
          dts: non_neg_integer(),
          pts: integer(),
          size: non_neg_integer(),
          offset: non_neg_integer(),
          sync?: boolean()
        }
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/sample_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/sample.ex test/iso_media/sample_test.exs
git commit -m "feat: add Sample struct"
```

---

### Task 2: `ISOMedia.SampleTable.build/1`

**Files:**
- Create: `lib/iso_media/sample_table.ex`
- Test: `test/iso_media/sample_table_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/sample_table_test.exs`. It hand-builds one `trak` with known tables (3 samples across 2 chunks) so the expected index is transparent:

```elixir
defmodule ISOMedia.SampleTableTest do
  use ExUnit.Case
  alias ISOMedia.{SampleTable, Sample}

  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  # 3 samples: sizes 10/20/30; chunk1 = samples 1&2 @offset 1000, chunk2 = sample 3 @offset 2000.
  defp sample_trak(extra \\ <<>>) do
    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf("stts", <<0, 0, 0, 0, 1::32, 3::32, 100::32>>)
    stsc = leaf("stsc", <<0, 0, 0, 0, 2::32, 1::32, 2::32, 1::32, 2::32, 1::32, 1::32>>)
    stsz = leaf("stsz", <<0, 0, 0, 0, 0::32, 3::32, 10::32, 20::32, 30::32>>)
    stco = leaf("stco", <<0, 0, 0, 0, 2::32, 1000::32, 2000::32>>)
    stbl = container("stbl", stsd <> stts <> stsc <> stsz <> stco <> extra)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 7::32, 0::32, 0::32>>)
    trak = container("trak", tkhd <> container("mdia", container("minf", stbl)))
    {:ok, [trak_box]} = ISOMedia.parse(trak)
    trak_box
  end

  test "builds the sample index by cross-referencing the tables" do
    samples = SampleTable.build(sample_trak())

    assert [s1, s2, s3] = samples
    assert %Sample{index: 1, chunk_index: 1, dts: 0, pts: 0, size: 10, offset: 1000, sync?: true} = s1
    assert %Sample{index: 2, chunk_index: 1, dts: 100, pts: 100, size: 20, offset: 1010, sync?: true} = s2
    assert %Sample{index: 3, chunk_index: 2, dts: 200, pts: 200, size: 30, offset: 2000, sync?: true} = s3
  end

  test "stss marks only listed samples as sync" do
    stss = leaf("stss", <<0, 0, 0, 0, 1::32, 1::32>>)
    samples = SampleTable.build(sample_trak(stss))
    assert Enum.map(samples, & &1.sync?) == [true, false, false]
  end

  test "ctts shifts pts relative to dts" do
    ctts = leaf("ctts", <<0, 0, 0, 0, 1::32, 3::32, 5::32>>)
    samples = SampleTable.build(sample_trak(ctts))
    assert Enum.map(samples, & &1.pts) == [5, 105, 205]
  end

  test "raises on stz2 (unsupported)" do
    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf("stts", <<0, 0, 0, 0, 1::32, 1::32, 1::32>>)
    stsc = leaf("stsc", <<0, 0, 0, 0, 1::32, 1::32, 1::32, 1::32>>)
    stz2 = leaf("stz2", <<0, 0, 0, 0, 0::24, 8, 1::32, 10>>)
    stco = leaf("stco", <<0, 0, 0, 0, 1::32, 1000::32>>)
    stbl = container("stbl", stsd <> stts <> stsc <> stz2 <> stco)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::32>>)
    trak = container("trak", tkhd <> container("mdia", container("minf", stbl)))
    {:ok, [trak_box]} = ISOMedia.parse(trak)
    assert_raise ArgumentError, ~r/stz2/, fn -> SampleTable.build(trak_box) end
  end

  test "raises when a required table is missing" do
    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stbl = container("stbl", stsd)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::32>>)
    trak = container("trak", tkhd <> container("mdia", container("minf", stbl)))
    {:ok, [trak_box]} = ISOMedia.parse(trak)
    assert_raise ArgumentError, fn -> SampleTable.build(trak_box) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/sample_table_test.exs`
Expected: FAIL — `ISOMedia.SampleTable.build/1 is undefined`.

- [ ] **Step 3: Write the implementation**

Create `lib/iso_media/sample_table.ex`:

```elixir
defmodule ISOMedia.SampleTable do
  @moduledoc """
  Decodes a track's `stbl` sample tables into an ordered list of `ISOMedia.Sample`.

  Cross-references `stsz` (sizes), `stsc` (sample→chunk runs), `stco`/`co64` (chunk
  offsets), `stts` (decode-time deltas), optional `ctts` (composition offsets) and
  `stss` (sync samples). Raises on `stz2` (unsupported) or a missing required table.
  """

  alias ISOMedia.{Box, FullBox, Sample}
  alias ISOMedia.Boxes.ChunkOffset

  @doc "Decode a `trak` box into `[%ISOMedia.Sample{}]`."
  def build(%Box{type: "trak"} = trak) do
    stbl = dig(trak, ~w(mdia minf stbl)) || raise ArgumentError, "trak is missing mdia/minf/stbl"

    sizes = sample_sizes(stbl)
    sample_count = length(sizes)
    chunk_offsets = chunk_offsets(stbl)
    spc = expand_stsc(stsc_entries(stbl), length(chunk_offsets))

    if Enum.sum(spc) != sample_count do
      raise ArgumentError,
            "stsc/stsz mismatch: chunks describe #{Enum.sum(spc)} samples but stsz has #{sample_count}"
    end

    dts = decode_dts(stbl, sample_count)
    ctts = decode_ctts(stbl, sample_count)
    sync = sync_set(stbl)

    assemble(sizes, chunk_offsets, spc, dts, ctts, sync)
  end

  # --- table decoders ---

  defp sample_sizes(stbl) do
    cond do
      box = dig(stbl, ["stsz"]) ->
        {_v, _f, <<sample_size::32, count::32, rest::binary>>} = FullBox.parse(box.data)

        if sample_size == 0 do
          sizes = for <<s::32 <- rest>>, do: s

          if length(sizes) != count,
            do: raise(ArgumentError, "stsz: declared #{count} sizes but found #{length(sizes)}")

          sizes
        else
          List.duplicate(sample_size, count)
        end

      dig(stbl, ["stz2"]) ->
        raise ArgumentError,
              "Unsupported sample-size table: stz2 (compact sizes). Please open an issue if you hit this."

      true ->
        raise ArgumentError, "stbl is missing stsz (sample size box)"
    end
  end

  defp chunk_offsets(stbl) do
    box = dig(stbl, ["stco"]) || dig(stbl, ["co64"]) || raise ArgumentError, "stbl is missing stco/co64"
    ChunkOffset.decode(box).offsets
  end

  defp stsc_entries(stbl) do
    box = dig(stbl, ["stsc"]) || raise ArgumentError, "stbl is missing stsc"
    {_v, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)
    for <<first_chunk::32, spc::32, _sdi::32 <- rest>>, do: {first_chunk, spc}
  end

  # Per-chunk samples-per-chunk for chunks 1..chunk_count (entries are runs).
  defp expand_stsc(entries, chunk_count) do
    sorted = Enum.sort_by(entries, &elem(&1, 0))

    Enum.map(1..chunk_count//1, fn c ->
      case sorted |> Enum.take_while(fn {fc, _} -> fc <= c end) |> List.last() do
        {_fc, spc} -> spc
        nil -> raise ArgumentError, "stsc: no run covers chunk #{c}"
      end
    end)
  end

  defp decode_dts(stbl, sample_count) do
    box = dig(stbl, ["stts"]) || raise ArgumentError, "stbl is missing stts"
    {_v, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)
    deltas = for <<n::32, delta::32 <- rest>>, do: {n, delta}
    per_sample = Enum.flat_map(deltas, fn {n, d} -> List.duplicate(d, n) end)

    if length(per_sample) != sample_count,
      do: raise(ArgumentError, "stts describes #{length(per_sample)} samples, expected #{sample_count}")

    {dts, _} = Enum.map_reduce(per_sample, 0, fn d, acc -> {acc, acc + d} end)
    dts
  end

  defp decode_ctts(stbl, sample_count) do
    case dig(stbl, ["ctts"]) do
      nil ->
        List.duplicate(0, sample_count)

      box ->
        {version, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)

        entries =
          case version do
            1 -> for <<n::32, off::signed-32 <- rest>>, do: {n, off}
            _ -> for <<n::32, off::32 <- rest>>, do: {n, off}
          end

        Enum.flat_map(entries, fn {n, off} -> List.duplicate(off, n) end)
    end
  end

  defp sync_set(stbl) do
    case dig(stbl, ["stss"]) do
      nil ->
        :all

      box ->
        {_v, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)
        MapSet.new(for <<n::32 <- rest>>, do: n)
    end
  end

  # --- assembly ---

  defp assemble(sizes, chunk_offsets, spc, dts, ctts, sync) do
    chunks = Enum.zip([1..length(chunk_offsets)//1, chunk_offsets, spc])

    {rev, _state} =
      Enum.reduce(chunks, {[], {1, sizes, dts, ctts}}, fn {cidx, coff, n}, {acc, {sidx, sz, dt, ct}} ->
        {csz, sz2} = Enum.split(sz, n)
        {cdt, dt2} = Enum.split(dt, n)
        {cct, ct2} = Enum.split(ct, n)

        {chunk_acc, _pos, _i} =
          Enum.reduce(Enum.zip([csz, cdt, cct]), {acc, coff, sidx}, fn {size, d, c}, {a, pos, i} ->
            sample = %Sample{
              index: i,
              chunk_index: cidx,
              dts: d,
              pts: d + c,
              size: size,
              offset: pos,
              sync?: sync == :all or MapSet.member?(sync, i)
            }

            {[sample | a], pos + size, i + 1}
          end)

        {chunk_acc, {sidx + n, sz2, dt2, ct2}}
      end)

    Enum.reverse(rev)
  end

  # Navigate a single box by child-type path (e.g. dig(trak, ~w(mdia minf stbl))).
  defp dig(%Box{type: type} = box, path), do: Box.find([box], [type | path])
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/sample_table_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/sample_table.ex test/iso_media/sample_table_test.exs
git commit -m "feat: SampleTable.build decodes stbl into a sample index"
```

---

### Task 3: `ISOMedia.samples/2` + `track_ids/1` + `ISOMedia.Extract.find_trak`

**Files:**
- Create: `lib/iso_media/extract.ex` (track lookup now; `extract_track/2` added in Task 6)
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media_test.exs`:

```elixir
  describe "track discovery + samples" do
    test "track_ids and samples on the real fixture" do
      {:ok, boxes} = ISOMedia.read(Path.join([__DIR__, "fixtures", "sample.mp4"]))
      original = File.read!(Path.join([__DIR__, "fixtures", "sample.mp4"]))

      ids = ISOMedia.track_ids(boxes)
      assert ids != []
      tid = hd(ids)

      samples = ISOMedia.samples(boxes, tid)
      assert samples != []
      # dts monotonic non-decreasing
      dts = Enum.map(samples, & &1.dts)
      assert dts == Enum.sort(dts)
      # every sample lies within the file
      assert Enum.all?(samples, &(&1.offset + &1.size <= byte_size(original)))
      # at least one sync sample
      assert Enum.any?(samples, & &1.sync?)
    end

    test "samples/2 raises for an unknown track id" do
      {:ok, boxes} = ISOMedia.read(Path.join([__DIR__, "fixtures", "sample.mp4"]))
      assert_raise ArgumentError, fn -> ISOMedia.samples(boxes, 9999) end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media_test.exs`
Expected: FAIL — `ISOMedia.track_ids/1 is undefined`.

- [ ] **Step 3: Write the track-lookup module**

Create `lib/iso_media/extract.ex`:

```elixir
defmodule ISOMedia.Extract do
  @moduledoc """
  Track discovery and single-track extraction.

  `track_ids/1` and `find_trak/2` locate tracks by their `tkhd` track_id;
  `extract_track/2` (added later) produces a new single-track tree.
  """

  alias ISOMedia.Box
  alias ISOMedia.Boxes.TrackHeader

  @doc "List every track's `track_id`, in document order."
  def track_ids(boxes) do
    boxes
    |> traks()
    |> Enum.map(&track_id_of/1)
  end

  @doc "Find the `trak` box whose `tkhd` track_id matches, or `nil`."
  def find_trak(boxes, track_id) do
    boxes
    |> traks()
    |> Enum.find(fn trak -> track_id_of(trak) == track_id end)
  end

  defp traks(boxes) do
    case Enum.find(boxes, &(&1.type == "moov")) do
      nil -> []
      moov -> Enum.filter(moov.children, &(&1.type == "trak"))
    end
  end

  defp track_id_of(%Box{} = trak) do
    tkhd = Box.find([trak], ~w(trak tkhd)) || raise ArgumentError, "trak is missing tkhd"
    TrackHeader.decode(tkhd).track_id
  end
end
```

- [ ] **Step 4: Add the public API**

In `lib/iso_media.ex`, add (after `serialize/1`):

```elixir
  @doc "List the `track_id`s present in the movie."
  def track_ids(boxes), do: ISOMedia.Extract.track_ids(boxes)

  @doc "Decode a track's sample tables into `[%ISOMedia.Sample{}]`."
  def samples(boxes, track_id) do
    case ISOMedia.Extract.find_trak(boxes, track_id) do
      nil -> raise ArgumentError, "no track with track_id #{track_id}"
      trak -> ISOMedia.SampleTable.build(trak)
    end
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/iso_media_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/iso_media/extract.ex lib/iso_media.ex test/iso_media_test.exs
git commit -m "feat: track_ids/1 and samples/2 (sample index by track)"
```

---

### Task 4: Segment-list payload (`Box`/`Layout`/`Serializer`)

**Files:**
- Modify: `lib/iso_media/box.ex`, `lib/iso_media/layout.ex`, `lib/iso_media/serializer.ex`
- Test: `test/iso_media/serializer_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/serializer_test.exs`:

```elixir
  describe "segment-list payload" do
    setup do
      path = Path.join(System.tmp_dir!(), "iso_seg_#{System.unique_integer([:positive])}.bin")
      File.write!(path, <<0, 1, 2, 3, 4, 5, 6, 7>>)
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "box_size sums binary + FileSlice parts", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      box = %ISOMedia.Box{type: "mdat", data: parts}
      # header 8 + (2 + 3)
      assert ISOMedia.Layout.box_size(box) == 13
    end

    test "serialize materializes a segment list", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      box = %ISOMedia.Box{type: "mdat", data: parts}
      assert ISOMedia.Serializer.serialize([box]) == <<13::32, "mdat", 9, 9, 2, 3, 4>>
    end

    test "stream writes each segment in order", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      box = %ISOMedia.Box{type: "mdat", data: parts}
      out = Path.join(System.tmp_dir!(), "iso_seg_out_#{System.unique_integer([:positive])}.bin")
      on_exit(fn -> File.rm(out) end)
      File.open!(out, [:write, :binary, :raw], fn io -> ISOMedia.Serializer.stream([box], io, 2) end)
      assert File.read!(out) == <<13::32, "mdat", 9, 9, 2, 3, 4>>
    end

    test "read_data concatenates the parts", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      assert ISOMedia.Box.read_data(%ISOMedia.Box{type: "mdat", data: parts}) == <<9, 9, 2, 3, 4>>
    end

    test "to_iodata raises on a raw segment list", %{path: path} do
      parts = [<<9, 9>>, %ISOMedia.FileSlice{path: path, offset: 2, length: 3}]
      box = %ISOMedia.Box{type: "mdat", data: parts}
      assert_raise ArgumentError, ~r/segment list/, fn -> ISOMedia.Serializer.to_iodata([box]) end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: FAIL — `Layout.box_size` raises / wrong result on a list payload.

- [ ] **Step 3: Box — list in `read_data/1` and `@type t`**

In `lib/iso_media/box.ex`, widen the `@type t` `data` line to:

```elixir
          data: binary() | ISOMedia.FileSlice.t() | [binary() | ISOMedia.FileSlice.t()] | nil,
```

And add a `read_data/1` clause for lists, between the `FileSlice` clause and the catch-all:

```elixir
  def read_data(%__MODULE__{data: %ISOMedia.FileSlice{} = slice}), do: ISOMedia.FileSlice.read(slice)

  def read_data(%__MODULE__{data: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %ISOMedia.FileSlice{} = s -> ISOMedia.FileSlice.read(s)
      bin when is_binary(bin) -> bin
    end)
    |> IO.iodata_to_binary()
  end

  def read_data(%__MODULE__{data: data}), do: data
```

- [ ] **Step 4: Layout — list clause in `box_size/1`**

In `lib/iso_media/layout.ex`, add this clause immediately after the existing `%FileSlice{}` clause (before the `data: nil` and binary clauses):

```elixir
  def box_size(%Box{data: parts} = box) when is_list(parts) do
    header_size(box) +
      Enum.sum(
        Enum.map(parts, fn
          %FileSlice{length: len} -> len
          bin when is_binary(bin) -> byte_size(bin)
        end)
      )
  end
```

- [ ] **Step 5: Serializer — list in `materialize`, `stream`, `to_iodata`**

In `lib/iso_media/serializer.ex`:

(a) add a `materialize_box/1` clause for lists, after the `FileSlice` clause:

```elixir
  defp materialize_box(%Box{data: %FileSlice{} = slice} = box), do: %{box | data: FileSlice.read(slice)}

  defp materialize_box(%Box{data: parts} = box) when is_list(parts) do
    bytes =
      parts
      |> Enum.map(fn
        %FileSlice{} = s -> FileSlice.read(s)
        bin when is_binary(bin) -> bin
      end)
      |> IO.iodata_to_binary()

    %{box | data: bytes}
  end
```

(b) add an `encode_payload/1` clause for lists, placed with the other raising guards (after the `data: nil` clause, alongside the `%FileSlice{}` raise, before the binary clause):

```elixir
  defp encode_payload(%Box{data: parts}) when is_list(parts) do
    raise ArgumentError,
          "box payload is a segment list; use ISOMedia.write/2 to stream it, " <>
            "or ISOMedia.serialize/1 to materialize it into memory"
  end
```

(c) add a `stream_payload/3` clause for lists, after the `FileSlice` clause:

```elixir
  defp stream_payload(%Box{data: %FileSlice{} = slice}, io, chunk), do: FileSlice.stream(slice, io, chunk)

  defp stream_payload(%Box{data: parts}, io, chunk) when is_list(parts) do
    Enum.each(parts, fn
      %FileSlice{} = s -> FileSlice.stream(s, io, chunk)
      bin when is_binary(bin) -> write!(io, bin)
    end)
  end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: PASS.

- [ ] **Step 7: Run the full suite + format**

Run: `mix test && mix format && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: all green, format-clean, no warnings.

- [ ] **Step 8: Commit**

```bash
git add lib/iso_media/box.ex lib/iso_media/layout.ex lib/iso_media/serializer.ex test/iso_media/serializer_test.exs
git commit -m "feat: segment-list leaf payloads (binary | FileSlice parts)"
```

---

### Task 5: Extend `MP4Builder` to full `stbl` + multi-track

**Files:**
- Modify: `test/support/mp4_builder.ex`
- Test: `test/iso_media/mp4_builder_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/mp4_builder_test.exs`:

```elixir
  test "build_tracks produces a parseable multi-track file with a correct sample index" do
    # Track 7: 2 chunks ([s1,s2],[s3]); Track 8: 1 chunk ([s4,s5]). Distinct marker bytes.
    specs = [
      %{id: 7, chunks: [[<<1, 1>>, <<2, 2, 2>>], [<<3>>]]},
      %{id: 8, chunks: [[<<4, 4, 4, 4>>, <<5>>]]}
    ]

    %{binary: bin} = ISOMedia.Support.MP4Builder.build_tracks(specs)
    assert {:ok, boxes} = ISOMedia.parse(bin)
    assert ISOMedia.serialize(boxes) == bin
    assert Enum.sort(ISOMedia.track_ids(boxes)) == [7, 8]

    # Track 7's samples resolve to the exact marker bytes.
    s7 = ISOMedia.samples(boxes, 7)
    assert Enum.map(s7, & &1.size) == [2, 3, 1]
    assert Enum.map(s7, &binary_part(bin, &1.offset, &1.size)) == [<<1, 1>>, <<2, 2, 2>>, <<3>>]

    s8 = ISOMedia.samples(boxes, 8)
    assert Enum.map(s8, &binary_part(bin, &1.offset, &1.size)) == [<<4, 4, 4, 4>>, <<5>>]
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/mp4_builder_test.exs`
Expected: FAIL — `ISOMedia.Support.MP4Builder.build_tracks/1 is undefined`.

- [ ] **Step 3: Add `build_tracks/1`**

In `test/support/mp4_builder.ex`, add (the existing `leaf/2`, `container/2`, `build/1,2` stay):

```elixir
  @doc """
  Build a multi-track file from specs `%{id: track_id, chunks: [[sample_binary]]}`.
  Chunks are interleaved round-robin across tracks in the mdat (so a track's chunks
  are scattered, exercising real extraction). Returns
  `%{binary: binary, specs: specs}`.
  """
  def build_tracks(specs) when is_list(specs) and specs != [] do
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)

    # mdat layout: round-robin chunk i of each track, in spec order.
    interleave = interleave_chunks(specs)
    chunk_lengths = Enum.map(interleave, fn {_id, bytes} -> byte_size(bytes) end)

    # Two-pass: size moov with zero offsets, then place real ones. Table sizes are
    # independent of offset *values*, so moov's byte size is stable.
    zero = Map.new(specs, fn s -> {s.id, List.duplicate(0, length(s.chunks))} end)
    mdat_payload_start = byte_size(ftyp) + byte_size(moov(specs, zero)) + 8

    {abs_offsets, _} =
      Enum.map_reduce(chunk_lengths, mdat_payload_start, fn len, pos -> {pos, pos + len} end)

    per_track = group_offsets(interleave, abs_offsets)
    mdat_payload = IO.iodata_to_binary(Enum.map(interleave, fn {_id, b} -> b end))
    binary = ftyp <> moov(specs, per_track) <> leaf("mdat", mdat_payload)

    %{binary: binary, specs: specs}
  end

  defp interleave_chunks(specs) do
    per_track = Enum.map(specs, fn s -> {s.id, Enum.map(s.chunks, &IO.iodata_to_binary/1)} end)
    max_len = per_track |> Enum.map(fn {_id, cs} -> length(cs) end) |> Enum.max()

    for i <- 0..(max_len - 1)//1,
        {id, cs} <- per_track,
        i < length(cs),
        do: {id, Enum.at(cs, i)}
  end

  defp group_offsets(interleave, offsets) do
    interleave
    |> Enum.zip(offsets)
    |> Enum.reduce(%{}, fn {{id, _b}, off}, acc -> Map.update(acc, id, [off], &(&1 ++ [off])) end)
  end

  defp moov(specs, offsets_map) do
    traks = Enum.map(specs, fn s -> trak(s, Map.fetch!(offsets_map, s.id)) end)
    container("moov", IO.iodata_to_binary(traks))
  end

  defp trak(spec, chunk_offsets) do
    sample_sizes = spec.chunks |> List.flatten() |> Enum.map(&byte_size/1)
    spc = Enum.map(spec.chunks, &length/1)
    n = length(sample_sizes)

    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf("stts", <<0, 0, 0, 0, 1::32, n::32, 1::32>>)
    stsc = stsc_box(spc)
    stsz = leaf("stsz", <<0, 0, 0, 0, 0::32, n::32, sizes_bin(sample_sizes)::binary>>)
    stco = leaf("stco", <<0, 0, 0, 0, length(chunk_offsets)::32, offsets_bin(chunk_offsets)::binary>>)
    stbl = container("stbl", stsd <> stts <> stsc <> stsz <> stco)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, spec.id::32, 0::32, 0::32>>)
    container("trak", tkhd <> container("mdia", container("minf", stbl)))
  end

  defp stsc_box(spc) do
    entries =
      spc
      |> Enum.with_index(1)
      |> Enum.map(fn {n, i} -> <<i::32, n::32, 1::32>> end)
      |> IO.iodata_to_binary()

    leaf("stsc", <<0, 0, 0, 0, length(spc)::32, entries::binary>>)
  end

  defp sizes_bin(sizes), do: for(s <- sizes, into: <<>>, do: <<s::32>>)
  defp offsets_bin(offsets), do: for(o <- offsets, into: <<>>, do: <<o::32>>)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/mp4_builder_test.exs`
Expected: PASS (existing builder test + the new multi-track test).

- [ ] **Step 5: Commit**

```bash
git add test/support/mp4_builder.ex test/iso_media/mp4_builder_test.exs
git commit -m "test: MP4Builder full-stbl multi-track build_tracks"
```

---

### Task 6: `ISOMedia.Extract.extract_track/2`

**Files:**
- Modify: `lib/iso_media/extract.ex`, `lib/iso_media.ex`
- Test: `test/iso_media/extract_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/extract_test.exs`:

```elixir
defmodule ISOMedia.ExtractTest do
  use ExUnit.Case
  alias ISOMedia.Support.MP4Builder

  defp parsed(specs) do
    %{binary: bin} = MP4Builder.build_tracks(specs)
    path = Path.join(System.tmp_dir!(), "iso_ex_#{System.unique_integer([:positive])}.mp4")
    File.write!(path, bin)
    on_exit(fn -> File.rm(path) end)
    {bin, path}
  end

  @specs [
    %{id: 7, chunks: [[<<1, 1>>, <<2, 2, 2>>], [<<3>>]]},
    %{id: 8, chunks: [[<<4, 4, 4, 4>>, <<5>>]]}
  ]

  test "extract_track keeps one track and its samples resolve to the original bytes" do
    {bin, _path} = parsed(@specs)
    {:ok, boxes} = ISOMedia.parse(bin)

    out_boxes = ISOMedia.extract_track(boxes, 7)
    out = ISOMedia.serialize(out_boxes)
    {:ok, reparsed} = ISOMedia.parse(out)

    assert ISOMedia.track_ids(reparsed) == [7]

    extracted = ISOMedia.samples(reparsed, 7)
    assert Enum.map(extracted, &binary_part(out, &1.offset, &1.size)) == [<<1, 1>>, <<2, 2, 2>>, <<3>>]
  end

  test "lazy extract streams to disk and matches an eager extract" do
    {bin, path} = parsed(@specs)

    {:ok, eager} = ISOMedia.read(path)
    eager_out = eager |> ISOMedia.extract_track(7) |> ISOMedia.serialize()

    {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)
    lazy_tree = ISOMedia.extract_track(lazy, 7)
    # the new mdat is a segment list of FileSlices (not materialized)
    assert is_list(ISOMedia.Box.find(lazy_tree, ~w(mdat)).data)

    out = Path.join(System.tmp_dir!(), "iso_ex_out_#{System.unique_integer([:positive])}.mp4")
    on_exit(fn -> File.rm(out) end)
    assert :ok = ISOMedia.write(out, lazy_tree)
    assert File.read!(out) == eager_out
  end

  test "raises for an unknown track id" do
    {bin, _path} = parsed(@specs)
    {:ok, boxes} = ISOMedia.parse(bin)
    assert_raise ArgumentError, fn -> ISOMedia.extract_track(boxes, 999) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/extract_test.exs`
Expected: FAIL — `ISOMedia.extract_track/2 is undefined`.

- [ ] **Step 3: Implement `extract_track/2`**

In `lib/iso_media/extract.ex`, add the aliases and the function. Update the top `alias` line to:

```elixir
  alias ISOMedia.{Box, FileSlice, Layout, SampleTable}
  alias ISOMedia.Boxes.{ChunkOffset, TrackHeader}
```

Add:

```elixir
  @uint32_max 0xFFFFFFFF

  @doc """
  Return a new box tree containing only the track `track_id`, with `mdat` rebuilt as a
  segment list of that track's chunks and `stco`/`co64` recomputed. Memory-safe: with a
  lazy source the segments are `FileSlice`s streamed on `write/2`.
  """
  def extract_track(boxes, track_id) do
    trak = find_trak(boxes, track_id) || raise ArgumentError, "no track with track_id #{track_id}"
    ftyp = Enum.find(boxes, &(&1.type == "ftyp")) || raise ArgumentError, "file has no ftyp"
    mdats = Enum.filter(boxes, &(&1.type == "mdat"))

    runs =
      trak
      |> SampleTable.build()
      |> Enum.chunk_by(& &1.chunk_index)
      |> Enum.map(fn chunk_samples ->
        {hd(chunk_samples).offset, Enum.sum(Enum.map(chunk_samples, & &1.size))}
      end)

    segments = Enum.map(runs, fn {off, len} -> segment_for(mdats, off, len) end)
    run_lengths = Enum.map(runs, fn {_o, l} -> l end)
    total = Enum.sum(run_lengths)
    chunk_count = length(runs)

    zeros = List.duplicate(0, chunk_count)

    # Decide co64 vs stco and the mdat header size up front (both knowable now).
    # Upper bound uses the larger co64 table + 16-byte mdat header; output ≤ original.
    co64_bound =
      Layout.box_size(ftyp) + Layout.box_size(rebuild_moov(boxes, trak, offset_box(:co64, zeros))) +
        16 + total

    co_kind = if co64_bound > @uint32_max, do: :co64, else: :stco
    mdat_mode = if 8 + total > @uint32_max, do: :large, else: :compact
    mdat_header = if mdat_mode == :large, do: 16, else: 8

    # Size moov with dummy offsets of the chosen kind, then place real offsets.
    moov0 = rebuild_moov(boxes, trak, offset_box(co_kind, zeros))
    mdat_payload_start = Layout.box_size(ftyp) + Layout.box_size(moov0) + mdat_header

    {chunk_offsets, _} =
      Enum.map_reduce(run_lengths, mdat_payload_start, fn len, pos -> {pos, pos + len} end)

    moov = rebuild_moov(boxes, trak, offset_box(co_kind, chunk_offsets))
    mdat = %Box{type: "mdat", data: segments, size_mode: mdat_mode}
    [ftyp, moov, mdat]
  end

  # --- helpers ---

  defp offset_box(kind, offsets) do
    ChunkOffset.encode(%ChunkOffset{kind: kind, version: 0, flags: <<0, 0, 0>>, offsets: offsets})
  end

  defp segment_for(mdats, offset, length) do
    mdat =
      Enum.find(mdats, fn m ->
        not is_nil(m.source_offset) and offset >= m.source_offset and
          offset < m.source_offset + m.source_size
      end) || raise ArgumentError, "sample chunk at offset #{offset} falls outside every mdat"

    case mdat.data do
      %FileSlice{path: path} ->
        %FileSlice{path: path, offset: offset, length: length}

      bin when is_binary(bin) ->
        payload_start = mdat.source_offset + Layout.header_size(mdat)
        binary_part(bin, offset - payload_start, length)

      _ ->
        raise ArgumentError, "cannot extract from an mdat whose payload is already a segment list"
    end
  end

  defp rebuild_moov(boxes, trak, new_offset_box) do
    moov = Enum.find(boxes, &(&1.type == "moov"))
    kept = replace_offset_box(trak, new_offset_box)
    keep_id = track_id_of(trak)

    children =
      Enum.flat_map(moov.children, fn
        %Box{type: "trak"} = t -> if track_id_of(t) == keep_id, do: [kept], else: []
        other -> [other]
      end)

    %{moov | children: children}
  end

  defp replace_offset_box(trak, new_box) do
    update_descendant(trak, ~w(mdia minf stbl), fn stbl ->
      children =
        Enum.map(stbl.children, fn
          %Box{type: t} when t in ["stco", "co64"] -> new_box
          other -> other
        end)

      %{stbl | children: children}
    end)
  end

  defp update_descendant(box, [], fun), do: fun.(box)

  defp update_descendant(%Box{children: children} = box, [type | rest], fun) do
    new_children =
      Enum.map(children, fn
        %Box{type: ^type} = c -> update_descendant(c, rest, fun)
        other -> other
      end)

    %{box | children: new_children}
  end
```

- [ ] **Step 4: Add the public delegation**

In `lib/iso_media.ex`, add (after `samples/2`):

```elixir
  @doc "Extract a single track into a new box tree (then `write/2` or `serialize/1`)."
  def extract_track(boxes, track_id), do: ISOMedia.Extract.extract_track(boxes, track_id)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/iso_media/extract_test.exs`
Expected: PASS (3 tests). (If the offset/byte assertions fail, the chunk-offset math or `segment_for` slicing is wrong — debug `Extract`, do not weaken assertions.)

- [ ] **Step 6: Run full suite + format**

Run: `mix test && mix format && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: all green, format-clean, no warnings.

- [ ] **Step 7: Commit**

```bash
git add lib/iso_media/extract.ex lib/iso_media.ex test/iso_media/extract_test.exs
git commit -m "feat: extract_track rebuilds mdat + chunk offsets for one track"
```

---

### Task 7: Real two-track fixture + integration test

**Files:**
- Create: `test/fixtures/sample_av.mp4` (generated)
- Modify: `test/fixtures/README.md`
- Test: `test/iso_media/extract_av_test.exs`

- [ ] **Step 1: Generate a 2-track (video + audio) fixture**

Run:
```bash
ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 \
  -f lavfi -i sine=frequency=440:duration=1 \
  -pix_fmt yuv420p -c:a aac -shortest test/fixtures/sample_av.mp4
ls -la test/fixtures/sample_av.mp4
```
Expected: a small file (well under ~200 KB) with both a video and an audio track.

- [ ] **Step 2: Document regeneration**

Append to `test/fixtures/README.md`:

```markdown
    # Two-track (video + audio) fixture for track extraction:
    ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 \
      -f lavfi -i sine=frequency=440:duration=1 \
      -pix_fmt yuv420p -c:a aac -shortest sample_av.mp4
```

- [ ] **Step 3: Write the integration test**

Create `test/iso_media/extract_av_test.exs`:

```elixir
defmodule ISOMedia.ExtractAvTest do
  use ExUnit.Case

  @fixture Path.join([__DIR__, "..", "fixtures", "sample_av.mp4"])

  test "the fixture has two tracks" do
    {:ok, boxes} = ISOMedia.read(@fixture)
    assert length(ISOMedia.track_ids(boxes)) == 2
  end

  test "extracting a track yields a one-track file whose samples match the originals" do
    original = File.read!(@fixture)
    {:ok, boxes} = ISOMedia.read(@fixture)
    [tid | _] = ISOMedia.track_ids(boxes)

    original_samples = ISOMedia.samples(boxes, tid)

    out_boxes = ISOMedia.extract_track(boxes, tid)
    out = ISOMedia.serialize(out_boxes)
    {:ok, reparsed} = ISOMedia.parse(out)

    assert ISOMedia.track_ids(reparsed) == [tid]
    extracted = ISOMedia.samples(reparsed, tid)
    assert length(extracted) == length(original_samples)

    # Each extracted sample's bytes equal the original sample's bytes.
    Enum.zip(original_samples, extracted)
    |> Enum.each(fn {o, e} ->
      assert e.size == o.size
      assert binary_part(out, e.offset, e.size) == binary_part(original, o.offset, o.size)
    end)
  end

  test "lazy extraction streams the kept track and matches eager" do
    {:ok, eager} = ISOMedia.read(@fixture)
    [tid | _] = ISOMedia.track_ids(eager)
    eager_out = eager |> ISOMedia.extract_track(tid) |> ISOMedia.serialize()

    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    out = Path.join(System.tmp_dir!(), "iso_av_#{System.unique_integer([:positive])}.mp4")
    on_exit(fn -> File.rm(out) end)
    assert :ok = ISOMedia.write(out, ISOMedia.extract_track(lazy, tid))
    assert File.read!(out) == eager_out
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/extract_av_test.exs`
Expected: PASS (3 tests). (If a sample-byte assertion fails on the real file, the extraction is genuinely wrong — debug, do not weaken.)

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/sample_av.mp4 test/fixtures/README.md test/iso_media/extract_av_test.exs
git commit -m "test: real 2-track fixture and extraction integration test"
```

---

### Task 8: Property test + docs

**Files:**
- Create: `test/iso_media/extract_property_test.exs`
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Write the property test**

Create `test/iso_media/extract_property_test.exs`:

```elixir
defmodule ISOMedia.ExtractPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Support.MP4Builder

  # A chunk is 1..3 samples of 1..6 bytes each (distinct marker bytes).
  defp chunk_gen, do: list_of(binary(min_length: 1, max_length: 6), min_length: 1, max_length: 3)

  # A movie is 2..3 tracks, each 1..3 chunks; track ids assigned 1..n.
  defp movie do
    gen all(
          tracks <-
            list_of(list_of(chunk_gen(), min_length: 1, max_length: 3), min_length: 2, max_length: 3)
        ) do
      specs = tracks |> Enum.with_index(1) |> Enum.map(fn {chunks, id} -> %{id: id, chunks: chunks} end)
      %{specs: specs, binary: MP4Builder.build_tracks(specs).binary}
    end
  end

  defp tmp, do: Path.join(System.tmp_dir!(), "iso_exp_#{System.unique_integer([:positive])}.mp4")

  property "extracting any track yields one track whose samples are byte-identical to the originals" do
    check all(%{specs: specs, binary: bin} <- movie()) do
      {:ok, boxes} = ISOMedia.parse(bin)

      for %{id: id, chunks: chunks} <- specs do
        expected = chunks |> List.flatten()
        out = boxes |> ISOMedia.extract_track(id) |> ISOMedia.serialize()
        {:ok, reparsed} = ISOMedia.parse(out)

        assert ISOMedia.track_ids(reparsed) == [id]
        got = ISOMedia.samples(reparsed, id) |> Enum.map(&binary_part(out, &1.offset, &1.size))
        assert got == expected
      end
    end
  end

  property "lazy extract-write == eager extract-serialize" do
    check all(%{specs: specs, binary: bin} <- movie()) do
      path = tmp()
      File.write!(path, bin)

      try do
        {:ok, eager} = ISOMedia.read(path)
        {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)

        for %{id: id} <- specs do
          eager_out = eager |> ISOMedia.extract_track(id) |> ISOMedia.serialize()
          out = tmp()

          try do
            :ok = ISOMedia.write(out, ISOMedia.extract_track(lazy, id))
            assert File.read!(out) == eager_out
          after
            File.rm(out)
          end
        end
      after
        File.rm(path)
      end
    end
  end
end
```

- [ ] **Step 2: Run the property suite**

Run: `mix test test/iso_media/extract_property_test.exs`
Expected: PASS (2 properties). (A failure is a real extraction/offset bug — StreamData shrinks to a minimal counterexample; debug, do not weaken.)

- [ ] **Step 3: Update the README**

In `README.md`, add after the "Large files" section:

```markdown
## Sample-level access

Read a track's samples, or demux a single track into its own file:

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")
ISOMedia.track_ids(boxes)            # => [1, 2]
ISOMedia.samples(boxes, 1)           # => [%ISOMedia.Sample{dts:, pts:, size:, offset:, sync?:, ...}, ...]

# Extract just track 1 (rebuilds mdat + chunk offsets; streams the media disk→disk under lazy:)
ISOMedia.write("track1.mp4", ISOMedia.extract_track(boxes, 1))
```

Extraction preserves the track's existing sample tables and chunking; it rebuilds
only `mdat` and `stco`/`co64`. Movie/track `mvhd`/`tkhd` durations are left as-is.
`stz2` sample sizes are not yet supported (raises). Trim and concatenation are
future phases.
```

- [ ] **Step 4: Update CLAUDE.md architecture**

In `CLAUDE.md`, add these bullets to the `## Architecture` module list:

```markdown
- `ISOMedia.Sample` (`lib/iso_media/sample.ex`) — one decoded sample (`index`, `chunk_index`, `dts`, `pts`, `size`, `offset`, `sync?`).
- `ISOMedia.SampleTable` (`lib/iso_media/sample_table.ex`) — `build/1` cross-references a track's `stbl` tables into `[%Sample{}]`. Reached via `ISOMedia.samples/2`.
- `ISOMedia.Extract` (`lib/iso_media/extract.ex`) — `track_ids/1`, `find_trak/2`, and `extract_track/2` (rebuilds `mdat` as a segment list + recomputes chunk offsets). Exposed as `ISOMedia.track_ids/1`, `ISOMedia.samples/2`, `ISOMedia.extract_track/2`.
```

And update the `ISOMedia.Box`/`Layout`/`Serializer` lines to note that a leaf `data` may also be a **segment list** `[binary | FileSlice]` (concatenated on materialize, streamed on `stream/3`).

- [ ] **Step 5: Verify + commit**

Run: `mix test && mix compile --warnings-as-errors && mix format --check-formatted`
Expected: all green, format-clean.

```bash
git add test/iso_media/extract_property_test.exs README.md CLAUDE.md
git commit -m "test: extraction property suite; docs for sample-level access"
```

---

## Self-Review Notes

- **Spec coverage:** `%Sample{}` (T1); `SampleTable.build` decoding stsz/stsc/stco/co64/stts/ctts/stss + stz2/missing raises (T2); `samples/2`+`track_ids/1`+`find_trak` (T3); segment-list payload across Box/Layout/Serializer + to_iodata guard (T4); `MP4Builder` full-stbl multi-track (T5); `extract_track` with up-front header-size/co64 decision + segment `mdat` + rebuilt stco (T6); real 2-track fixture + integration incl. lazy (T7); property suite + docs (T8). Out-of-scope (trim, concat, mvhd/tkhd tidy, stz2, fragmented/HEIF) excluded.
- **Type consistency:** `%Sample{index, chunk_index, dts, pts, size, offset, sync?}` consistent T1→T2→T6; `%ChunkOffset{kind, version, flags, offsets}` reused in SampleTable + Extract; segment list `[binary | FileSlice]` handled identically in `box_size`/`materialize`/`stream`/`read_data`; `Extract.find_trak/2`/`track_ids/1`/`extract_track/2` ↔ `ISOMedia.*` delegations.
- **Offset math:** `extract_track` decides `co_kind` and `mdat_mode` before sizing `moov` (resolves the chicken-and-egg); chunk count is preserved so the offset-table size is stable; `new_mdat_payload_start = box_size(ftyp) + byte_size(moov) + mdat_header`.
- **Placeholders:** none — every code/test step contains complete, clean content (the T6 offset helpers and T8 generators are final as written).
