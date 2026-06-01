# Chunk-Offset Rewriting + Faststart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make box rearrangement safe by recomputing `stco`/`co64` chunk-offset tables, and ship `ISOMedia.faststart/1` (move `moov` before `mdat`) as the marquee feature.

**Architecture:** The parser stamps each box's `source_offset`/`source_size`. `ISOMedia.Layout` computes new absolute offsets after editing. `ISOMedia.Offsets` remaps each `stco`/`co64` entry by the uniform per-`mdat` byte delta (delta = new mdat payload position − the mdat's `source_offset`-derived payload position), with `stco`→`co64` promotion via a latched fixpoint loop. After fixing, each `mdat`'s `source_offset` is updated to its new position so the operation is idempotent and composes across edit→fix cycles. `ISOMedia.Boxes.ChunkOffset` is the typed view for the offset tables.

**Tech Stack:** Elixir 1.19 / OTP 29, ExUnit, StreamData (property tests), ffmpeg fixture (`test/fixtures/sample.mp4`).

**Branch:** `feat/offset-faststart` (already created, holds the approved spec at `docs/superpowers/specs/2026-05-31-chunk-offset-faststart-design.md`).

**Conventions for every commit:** end the commit message with:
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 1: `Box` gains `source_offset` and `source_size`

**Files:**
- Modify: `lib/iso_media/box.ex`
- Test: `test/iso_media/box_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/box_test.exs` (inside the module):

```elixir
  test "source_offset and source_size default to nil" do
    box = %Box{type: "moov"}
    assert box.source_offset == nil
    assert box.source_size == nil
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/box_test.exs`
Expected: FAIL — `key :source_offset not found` / unknown key in struct.

- [ ] **Step 3: Add the fields**

In `lib/iso_media/box.ex`, replace the `defstruct` line and the `@type t` block with:

```elixir
  defstruct type: nil,
            data: nil,
            children: [],
            uuid: nil,
            size_mode: :compact,
            source_offset: nil,
            source_size: nil

  @type t :: %__MODULE__{
          type: String.t(),
          data: binary() | nil,
          children: [t()],
          uuid: <<_::128>> | nil,
          size_mode: :compact | :large | :eof,
          source_offset: non_neg_integer() | nil,
          source_size: non_neg_integer() | nil
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/iso_media/box_test.exs`
Expected: PASS (new test + all existing box tests, which pattern-match partially and are unaffected).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/box.ex test/iso_media/box_test.exs
git commit -m "feat: add source_offset/source_size metadata fields to Box"
```

---

### Task 2: Parser stamps `source_offset` and `source_size`

**Files:**
- Modify: `lib/iso_media/parser.ex`
- Test: `test/iso_media/parser_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/parser_test.exs`:

```elixir
  test "stamps source_offset and source_size on top-level and nested boxes" do
    # moov (size 24) { mvhd (size 8) ; free (size 8) } then a trailing free (size 8)
    inner = <<8::32, "mvhd", 8::32, "free">>
    moov = <<8 + byte_size(inner)::32, "moov", inner::binary>>
    bin = moov <> <<8::32, "free">>

    assert {:ok, [moov_box, free_box]} = Parser.parse(bin)

    assert moov_box.source_offset == 0
    assert moov_box.source_size == 24
    assert free_box.source_offset == 24
    assert free_box.source_size == 8

    [mvhd, inner_free] = moov_box.children
    assert mvhd.source_offset == 8
    assert mvhd.source_size == 8
    assert inner_free.source_offset == 16
    assert inner_free.source_size == 8
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/parser_test.exs`
Expected: FAIL — `source_offset` is `nil`.

- [ ] **Step 3: Thread the absolute offset through parsing**

In `lib/iso_media/parser.ex`, replace the `parse_boxes/2` and `parse_box/2` functions with these offset-aware versions (keep `take_payload`, `take_uuid`, and `container?` unchanged):

```elixir
  defp parse_boxes(binary, opts), do: parse_boxes(binary, opts, 0)

  defp parse_boxes(<<>>, _opts, _offset), do: []

  defp parse_boxes(binary, opts, offset) do
    {box, rest} = parse_box(binary, opts, offset)
    [box | parse_boxes(rest, opts, offset + box.source_size)]
  end

  defp parse_box(<<size::32, type::binary-size(4), after_type::binary>> = full, opts, offset) do
    {size_mode, payload, remainder} = take_payload(size, after_type)
    {uuid, payload} = take_uuid(type, payload)
    box_size = byte_size(full) - byte_size(remainder)
    payload_offset = offset + (box_size - byte_size(payload))

    box =
      if container?(type, payload, opts) do
        %Box{
          type: type,
          data: nil,
          children: parse_boxes(payload, opts, payload_offset),
          uuid: uuid,
          size_mode: size_mode,
          source_offset: offset,
          source_size: box_size
        }
      else
        %Box{
          type: type,
          data: payload,
          children: [],
          uuid: uuid,
          size_mode: size_mode,
          source_offset: offset,
          source_size: box_size
        }
      end

    {box, remainder}
  end
```

Note: `parse/2` already calls `parse_boxes(binary, opts)`, which now delegates to the 3-arity version starting at offset 0. The container branch recurses with `payload_offset` (the absolute offset where the box's payload begins).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/iso_media/parser_test.exs`
Expected: PASS (new test + all existing parser tests — they pattern-match partially).

- [ ] **Step 5: Run the full suite (round-trip must be unaffected)**

Run: `mix test`
Expected: PASS — the new fields don't affect serialization, so `parse |> serialize == bin` still holds.

- [ ] **Step 6: Commit**

```bash
git add lib/iso_media/parser.ex test/iso_media/parser_test.exs
git commit -m "feat: stamp source_offset/source_size during parsing"
```

---

### Task 3: `ISOMedia.Layout` — offset computation

**Files:**
- Create: `lib/iso_media/layout.ex`
- Test: `test/iso_media/layout_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/layout_test.exs`:

```elixir
defmodule ISOMedia.LayoutTest do
  use ExUnit.Case
  alias ISOMedia.{Box, Layout}

  test "header_size accounts for size_mode and uuid" do
    assert Layout.header_size(%Box{size_mode: :compact}) == 8
    assert Layout.header_size(%Box{size_mode: :large}) == 16
    assert Layout.header_size(%Box{size_mode: :eof}) == 8
    assert Layout.header_size(%Box{size_mode: :compact, uuid: <<0::128>>}) == 24
  end

  test "box_size matches the serializer's byte length" do
    box = %Box{type: "free", data: <<1, 2, 3, 4>>}
    assert Layout.box_size(box) == byte_size(ISOMedia.Serializer.serialize(box))

    nested = %Box{type: "moov", children: [%Box{type: "free", data: <<0>>}]}
    assert Layout.box_size(nested) == byte_size(ISOMedia.Serializer.serialize(nested))
  end

  test "top_level_layout gives absolute offset and payload_offset per box" do
    boxes = [
      %Box{type: "ftyp", data: <<0, 0, 0, 0>>},
      %Box{type: "mdat", data: <<9, 9, 9>>}
    ]

    [ftyp, mdat] = Layout.top_level_layout(boxes)
    assert ftyp.offset == 0
    assert ftyp.payload_offset == 8
    # ftyp box is 8 + 4 = 12 bytes
    assert mdat.offset == 12
    assert mdat.payload_offset == 20
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/layout_test.exs`
Expected: FAIL — `ISOMedia.Layout.header_size/1 is undefined`.

- [ ] **Step 3: Write the implementation**

Create `lib/iso_media/layout.ex`:

```elixir
defmodule ISOMedia.Layout do
  @moduledoc """
  Computes absolute byte offsets for a box tree in its current arrangement,
  matching exactly how `ISOMedia.Serializer` lays bytes out. Used to find where
  boxes land after editing so chunk offsets can be recomputed.
  """

  alias ISOMedia.Box

  @doc "Byte length of a box's header (size+type, +8 for largesize, +16 for uuid)."
  def header_size(%Box{size_mode: mode, uuid: uuid}) do
    base =
      case mode do
        :compact -> 8
        :large -> 16
        :eof -> 8
      end

    base + if(uuid, do: 16, else: 0)
  end

  @doc "Total serialized byte length of a box (header + uuid + payload/children)."
  def box_size(%Box{data: nil, children: children} = box) do
    header_size(box) + Enum.sum(Enum.map(children, &box_size/1))
  end

  def box_size(%Box{data: data} = box) do
    header_size(box) + byte_size(data)
  end

  @doc """
  Absolute layout of the top-level boxes: a list of
  `%{box: box, offset: abs_offset, payload_offset: abs_payload_offset}` in order.
  """
  def top_level_layout(boxes) when is_list(boxes) do
    {entries, _end} =
      Enum.map_reduce(boxes, 0, fn box, off ->
        entry = %{box: box, offset: off, payload_offset: off + header_size(box)}
        {entry, off + box_size(box)}
      end)

    entries
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/layout_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/layout.ex test/iso_media/layout_test.exs
git commit -m "feat: add Layout module for absolute offset computation"
```

---

### Task 4: `Serializer.to_iodata/1` + iodata-based `write/2` (memory win)

**Files:**
- Modify: `lib/iso_media/serializer.ex`
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media/serializer_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/serializer_test.exs`:

```elixir
  test "to_iodata returns iodata equal in bytes to serialize/1" do
    boxes = [%ISOMedia.Box{type: "free", data: <<1, 2, 3>>}, %ISOMedia.Box{type: "mdat", data: <<9>>}]
    iodata = ISOMedia.Serializer.to_iodata(boxes)
    assert IO.iodata_to_binary(iodata) == ISOMedia.Serializer.serialize(boxes)
  end

  test "to_iodata accepts a single box" do
    box = %ISOMedia.Box{type: "free", data: <<>>}
    assert IO.iodata_to_binary(ISOMedia.Serializer.to_iodata(box)) == <<8::32, "free">>
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: FAIL — `ISOMedia.Serializer.to_iodata/1 is undefined`.

- [ ] **Step 3: Add `to_iodata/1` and route `serialize/1` through it**

In `lib/iso_media/serializer.ex`, replace the two `serialize/1` clauses with:

```elixir
  @doc "Serialize a box or list of boxes to a binary."
  def serialize(boxes), do: boxes |> to_iodata() |> IO.iodata_to_binary()

  @doc "Serialize a box or list of boxes to iodata (no full-binary materialization)."
  def to_iodata(%Box{} = box), do: to_iodata([box])
  def to_iodata(boxes) when is_list(boxes), do: Enum.map(boxes, &encode_box/1)
```

(Leave `encode_box/1`, `encode_payload/1`, and `encode_header/2` unchanged.)

- [ ] **Step 4: Make `write/2` use iodata**

In `lib/iso_media.ex`, replace `write/2`:

```elixir
  @doc "Serialize boxes and write them to a file (streams iodata, no full-binary copy)."
  def write(path, boxes), do: File.write(path, ISOMedia.Serializer.to_iodata(boxes))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/iso_media/serializer_test.exs test/iso_media_test.exs`
Expected: PASS (new tests + existing serializer tests + the `read`/`write` round-trip test in `iso_media_test.exs`).

- [ ] **Step 6: Commit**

```bash
git add lib/iso_media/serializer.ex lib/iso_media.ex test/iso_media/serializer_test.exs
git commit -m "feat: add Serializer.to_iodata and stream write via iodata"
```

---

### Task 5: `ISOMedia.Boxes.ChunkOffset` typed view (`stco`/`co64`)

**Files:**
- Create: `lib/iso_media/boxes/chunk_offset.ex`
- Test: `test/iso_media/boxes/chunk_offset_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/boxes/chunk_offset_test.exs`:

```elixir
defmodule ISOMedia.Boxes.ChunkOffsetTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.ChunkOffset

  test "decodes a stco box (32-bit entries)" do
    data = <<0, 0, 0, 0, 3::32, 100::32, 200::32, 300::32>>
    co = ChunkOffset.decode(%Box{type: "stco", data: data})
    assert co.kind == :stco
    assert co.version == 0
    assert co.flags == <<0, 0, 0>>
    assert co.offsets == [100, 200, 300]
  end

  test "decodes a co64 box (64-bit entries)" do
    data = <<0, 0, 0, 0, 2::32, 5_000_000_000::64, 6_000_000_000::64>>
    co = ChunkOffset.decode(%Box{type: "co64", data: data})
    assert co.kind == :co64
    assert co.offsets == [5_000_000_000, 6_000_000_000]
  end

  test "stco round-trips" do
    box = %Box{type: "stco", data: <<0, 0, 0, 0, 2::32, 10::32, 20::32>>}
    assert ChunkOffset.encode(ChunkOffset.decode(box)) == box
  end

  test "co64 round-trips" do
    box = %Box{type: "co64", data: <<0, 0, 0, 0, 1::32, 9_000_000_000::64>>}
    assert ChunkOffset.encode(ChunkOffset.decode(box)) == box
  end

  test "encode regenerates entry_count" do
    co = %ChunkOffset{kind: :stco, version: 0, flags: <<0, 0, 0>>, offsets: [1, 2, 3, 4]}
    %Box{data: <<_v, _f::binary-size(3), count::32, _rest::binary>>} = ChunkOffset.encode(co)
    assert count == 4
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/boxes/chunk_offset_test.exs`
Expected: FAIL — `ISOMedia.Boxes.ChunkOffset.decode/1 is undefined`.

- [ ] **Step 3: Write the implementation**

Create `lib/iso_media/boxes/chunk_offset.ex`:

```elixir
defmodule ISOMedia.Boxes.ChunkOffset do
  @moduledoc """
  Typed view of the `stco` (32-bit) and `co64` (64-bit) Chunk Offset Boxes.
  `kind` is `:stco` or `:co64`; `offsets` is a list of absolute file offsets.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:kind, :version, :flags, :offsets]

  @type t :: %__MODULE__{
          kind: :stco | :co64,
          version: non_neg_integer(),
          flags: <<_::24>>,
          offsets: [non_neg_integer()]
        }

  @doc "Decode a `stco`/`co64` box into a `%ChunkOffset{}`."
  def decode(%Box{type: "stco", data: data}), do: do_decode(:stco, data, 32)
  def decode(%Box{type: "co64", data: data}), do: do_decode(:co64, data, 64)

  defp do_decode(kind, data, width) do
    {version, flags, <<_count::32, entries::binary>>} = FullBox.parse(data)
    offsets = for <<o::size(width) <- entries>>, do: o
    %__MODULE__{kind: kind, version: version, flags: flags, offsets: offsets}
  end

  @doc "Encode a `%ChunkOffset{}` back into a `stco`/`co64` box."
  def encode(%__MODULE__{kind: :stco} = co), do: do_encode(co, "stco", 32)
  def encode(%__MODULE__{kind: :co64} = co), do: do_encode(co, "co64", 64)

  defp do_encode(%__MODULE__{version: v, flags: f, offsets: offs}, type, width) do
    entries = for o <- offs, into: <<>>, do: <<o::size(width)>>
    body = [<<length(offs)::32>>, entries]
    %Box{type: type, data: IO.iodata_to_binary(FullBox.encode(v, f, body))}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/boxes/chunk_offset_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/boxes/chunk_offset.ex test/iso_media/boxes/chunk_offset_test.exs
git commit -m "feat: typed view for stco/co64 (ChunkOffset)"
```

---

### Task 6: `ISOMedia.Offsets.fix_chunk_offsets/1` — core remap

**Files:**
- Create: `lib/iso_media/offsets.ex`
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media/offsets_test.exs`

This task builds the remap, the no-op case, the integrity guards, and the unmappable guard. `co64` promotion is added in Task 7 (the code below already contains the latched fixpoint loop so Task 7 only adds tests, but the promotion branch is implemented here so the loop is correct from the start).

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/offsets_test.exs`:

```elixir
defmodule ISOMedia.OffsetsTest do
  use ExUnit.Case
  alias ISOMedia.Box

  # --- helpers: build a parsed tree with a stco pointing into an mdat ---
  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  defp stco_data(offsets) do
    entries = for o <- offsets, into: <<>>, do: <<o::32>>
    <<0, 0, 0, 0, length(offsets)::32, entries::binary>>
  end

  # Build ftyp + moov(stco) + mdat where stco points at chunk starts inside mdat.
  # Returns the parsed boxes. The mdat payload is `chunks` concatenated.
  defp build(chunks) do
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    mdat_payload = IO.iodata_to_binary(chunks)

    # moov size is independent of offset *values* (fixed 32-bit entries), so build
    # once with zeros to learn its size, then with the real offsets.
    n = length(chunks)
    moov0 = container("moov", leaf("stco", stco_data(List.duplicate(0, n))))
    mdat_payload_start = byte_size(ftyp) + byte_size(moov0) + 8

    {offsets, _} =
      Enum.map_reduce(chunks, mdat_payload_start, fn c, pos -> {pos, pos + byte_size(c)} end)

    moov = container("moov", leaf("stco", stco_data(offsets)))
    mdat = leaf("mdat", mdat_payload)
    {:ok, boxes} = ISOMedia.parse(ftyp <> moov <> mdat)
    %{boxes: boxes, offsets: offsets, chunks: chunks}
  end

  defp stco_offsets(boxes) do
    boxes
    |> ISOMedia.Box.find(~w(moov stco))
    |> ISOMedia.Boxes.ChunkOffset.decode()
    |> Map.fetch!(:offsets)
  end

  test "no-op: fixing an unmodified tree leaves offsets unchanged and serializes identically" do
    %{boxes: boxes} = build([<<1, 2>>, <<3, 4, 5>>])
    bin = ISOMedia.serialize(boxes)
    fixed = ISOMedia.fix_chunk_offsets(boxes)
    assert stco_offsets(fixed) == stco_offsets(boxes)
    assert ISOMedia.serialize(fixed) == bin
  end

  test "after inserting a free box before mdat, offsets shift by the free box size" do
    %{boxes: boxes, offsets: offsets} = build([<<1, 2>>, <<3, 4, 5>>])
    free = %Box{type: "free", data: <<0, 0, 0, 0>>}
    # free box total size = 8 + 4 = 12
    moved = List.insert_at(boxes, 1, free)
    fixed = ISOMedia.fix_chunk_offsets(moved)
    assert stco_offsets(fixed) == Enum.map(offsets, &(&1 + 12))
  end

  test "fixed offsets point at the correct chunk bytes after editing" do
    %{boxes: boxes, chunks: chunks} = build([<<10, 11>>, <<20, 21, 22>>, <<30>>])
    moved = List.insert_at(boxes, 1, %Box{type: "free", data: <<0, 0>>})
    fixed = ISOMedia.fix_chunk_offsets(moved)
    out = ISOMedia.serialize(fixed)

    chunks
    |> Enum.zip(stco_offsets(fixed))
    |> Enum.each(fn {chunk, off} ->
      assert binary_part(out, off, byte_size(chunk)) == chunk
    end)
  end

  test "raises when an mdat was synthesized (no source_offset)" do
    %{boxes: boxes} = build([<<1>>])
    # Replace mdat with a fresh (synthesized) one
    synth = %Box{type: "mdat", data: <<1>>}
    bad = Enum.map(boxes, fn b -> if b.type == "mdat", do: synth, else: b end)
    assert_raise ArgumentError, fn -> ISOMedia.fix_chunk_offsets(bad) end
  end

  test "raises when a chunk offset falls outside any mdat" do
    %{boxes: boxes} = build([<<1, 2>>])
    bad =
      ISOMedia.Box.update(boxes, ~w(moov stco), fn stco ->
        co = ISOMedia.Boxes.ChunkOffset.decode(stco)
        ISOMedia.Boxes.ChunkOffset.encode(%{co | offsets: [999_999]})
      end)

    assert_raise ArgumentError, fn -> ISOMedia.fix_chunk_offsets(bad) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/offsets_test.exs`
Expected: FAIL — `ISOMedia.fix_chunk_offsets/1 is undefined`.

- [ ] **Step 3: Write the implementation**

Create `lib/iso_media/offsets.ex`:

```elixir
defmodule ISOMedia.Offsets do
  @moduledoc """
  Recomputes `stco`/`co64` chunk-offset tables after boxes have moved, and the
  `faststart/1` rearrangement built on top of it.

  Assumes `mdat` payloads are byte-identical to what was parsed (this is box
  relocation, not sample editing). Each `mdat` carries its current basis position
  via `source_offset`/`source_size`, so a chunk offset is remapped by the uniform
  byte delta of the `mdat` it points into. After remapping, each `mdat`'s
  `source_offset` is updated to its new position, which makes the operation
  idempotent and lets repeated edit→fix cycles compose.
  """

  alias ISOMedia.Layout
  alias ISOMedia.Boxes.ChunkOffset

  @uint32_max 0xFFFFFFFF
  @max_iterations 16

  @doc """
  Return `boxes` with every `stco`/`co64` table corrected for the current
  arrangement. Promotes `stco`→`co64` (latched, never demoted) when an offset
  reaches the `:co64_threshold` (default `#{@uint32_max}`), iterating layout to a
  fixpoint. Raises if an `mdat` was synthesized or resized, or if a chunk offset
  maps into no `mdat`.

  Options:
    * `:co64_threshold` — promote a table to `co64` when any offset exceeds this
      value. Defaults to 2^32 − 1; lower it only in tests to exercise promotion
      without a multi-gigabyte file.
  """
  def fix_chunk_offsets(boxes, opts \\ []) when is_list(boxes) do
    threshold = Keyword.get(opts, :co64_threshold, @uint32_max)
    mdats = Enum.filter(boxes, &(&1.type == "mdat"))
    check_integrity!(mdats)
    originals = collect_tables(boxes)

    if originals == [] do
      boxes
    else
      boxes
      |> converge(originals, threshold, MapSet.new(), 0)
      |> rebase_mdats()
    end
  end

  @doc """
  Move `moov` to immediately after any leading `ftyp` (and before `mdat`), then fix
  chunk offsets. Returns the tree unchanged if it has no `moov` or no `mdat`.
  """
  def faststart(boxes, opts \\ []) when is_list(boxes) do
    has_moov = Enum.any?(boxes, &(&1.type == "moov"))
    has_mdat = Enum.any?(boxes, &(&1.type == "mdat"))

    if has_moov and has_mdat do
      boxes |> move_moov_first() |> fix_chunk_offsets(opts)
    else
      boxes
    end
  end

  # --- faststart rearrangement ---

  defp move_moov_first(boxes) do
    moov = Enum.find(boxes, &(&1.type == "moov"))
    without = Enum.reject(boxes, &(&1.type == "moov"))
    {leading_ftyp, rest} = Enum.split_while(without, &(&1.type == "ftyp"))
    leading_ftyp ++ [moov] ++ rest
  end

  # --- integrity ---

  defp check_integrity!(mdats) do
    Enum.each(mdats, fn m ->
      cond do
        is_nil(m.source_offset) or is_nil(m.source_size) ->
          raise ArgumentError,
                "fix_chunk_offsets: an mdat has no source position (synthesized?). " <>
                  "Sample-level editing is not supported in this phase."

        Layout.box_size(m) != m.source_size ->
          raise ArgumentError,
                "fix_chunk_offsets: an mdat changed size since parsing " <>
                  "(#{Layout.box_size(m)} vs #{m.source_size}). Sample-level editing " <>
                  "is out of scope."

        true ->
          :ok
      end
    end)
  end

  # --- fixpoint ---

  defp converge(_tree, _originals, _threshold, _promoted, iter) when iter > @max_iterations do
    raise ArgumentError, "fix_chunk_offsets: failed to converge after #{@max_iterations} iterations"
  end

  defp converge(tree, originals, threshold, promoted, iter) do
    {new_tree, new_promoted} = apply_offsets(tree, originals, threshold, promoted)

    if signatures(new_tree) == signatures(tree) do
      new_tree
    else
      converge(new_tree, originals, threshold, new_promoted, iter + 1)
    end
  end

  defp apply_offsets(tree, originals, threshold, promoted) do
    ranges = mdat_ranges(tree)
    {new_tree, {_i, new_promoted}} = walk_apply(tree, originals, ranges, threshold, {0, promoted})
    {new_tree, new_promoted}
  end

  # Each mdat's {old_start, old_end, delta}. old_* from the mdat's own source_*
  # (the basis the current offsets were written against); delta from its new
  # payload position in the current layout.
  defp mdat_ranges(tree) do
    tree
    |> Layout.top_level_layout()
    |> Enum.filter(&(&1.box.type == "mdat"))
    |> Enum.map(fn %{box: m, payload_offset: new_payload_start} ->
      old_payload_start = m.source_offset + Layout.header_size(m)
      {m.source_offset, m.source_offset + m.source_size, new_payload_start - old_payload_start}
    end)
  end

  # Walk the tree in document order, replacing the i-th stco/co64 box with its
  # remapped version. `originals` (same traversal order) supplies the basis offsets
  # so remapping is computed against a stable reference each iteration.
  defp walk_apply(boxes, originals, ranges, threshold, acc) do
    Enum.map_reduce(boxes, acc, fn box, {i, promoted} ->
      cond do
        box.type in ["stco", "co64"] ->
          orig = Enum.at(originals, i)
          new_offsets = Enum.map(orig.offsets, &(&1 + delta_for!(ranges, &1)))
          overflow? = Enum.any?(new_offsets, &(&1 > threshold))
          promoted = if overflow?, do: MapSet.put(promoted, i), else: promoted
          kind = if MapSet.member?(promoted, i), do: :co64, else: orig.kind

          new_box =
            ChunkOffset.encode(%ChunkOffset{
              kind: kind,
              version: orig.version,
              flags: orig.flags,
              offsets: new_offsets
            })

          {new_box, {i + 1, promoted}}

        box.data == nil ->
          {children, acc2} = walk_apply(box.children, originals, ranges, threshold, {i, promoted})
          {%{box | children: children}, acc2}

        true ->
          {box, {i, promoted}}
      end
    end)
  end

  defp delta_for!(ranges, offset) do
    case Enum.find(ranges, fn {s, e, _d} -> offset >= s and offset < e end) do
      {_s, _e, delta} ->
        delta

      nil ->
        raise ArgumentError,
              "fix_chunk_offsets: chunk offset #{offset} falls outside every mdat; cannot remap"
    end
  end

  # Update each top-level mdat's source_offset to its position in the final layout,
  # so the offsets now in the tree are consistent with the recorded basis. This is
  # what makes fix_chunk_offsets idempotent and composable across edits.
  defp rebase_mdats(tree) do
    new_offsets =
      tree
      |> Layout.top_level_layout()
      |> Enum.filter(&(&1.box.type == "mdat"))
      |> Enum.map(& &1.offset)

    {rebased, []} =
      Enum.map_reduce(tree, new_offsets, fn box, offs ->
        case {box.type, offs} do
          {"mdat", [o | rest]} -> {%{box | source_offset: o}, rest}
          _ -> {box, offs}
        end
      end)

    rebased
  end

  # Decoded chunk-offset tables in document order (matches walk_apply's order).
  defp collect_tables(boxes) do
    Enum.flat_map(boxes, fn box ->
      cond do
        box.type in ["stco", "co64"] -> [ChunkOffset.decode(box)]
        box.data == nil -> collect_tables(box.children)
        true -> []
      end
    end)
  end

  # {type, data} of each chunk-offset box in document order — used for fixpoint
  # stability comparison.
  defp signatures(boxes) do
    Enum.flat_map(boxes, fn box ->
      cond do
        box.type in ["stco", "co64"] -> [{box.type, box.data}]
        box.data == nil -> signatures(box.children)
        true -> []
      end
    end)
  end
end
```

Note on idempotence: `rebase_mdats/1` rewrites each `mdat`'s `source_offset` to its
new layout position after the offsets are fixed. So a second `fix_chunk_offsets`
call computes delta 0 (offsets already consistent with the recorded basis) and is a
no-op. The convergence loop runs entirely against the *entry* `source_offset`
values; rebasing happens only once, after the loop settles.

- [ ] **Step 4: Add the public API delegations**

In `lib/iso_media.ex`, add after `serialize/1` (and before `read/2`):

```elixir
  @doc "Recompute stco/co64 chunk offsets for the current box arrangement. See `ISOMedia.Offsets.fix_chunk_offsets/1`."
  def fix_chunk_offsets(boxes), do: ISOMedia.Offsets.fix_chunk_offsets(boxes)

  @doc "Move `moov` before `mdat` (faststart) and fix chunk offsets. See `ISOMedia.Offsets.faststart/1`."
  def faststart(boxes), do: ISOMedia.Offsets.faststart(boxes)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/iso_media/offsets_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS — all prior tests still green.

- [ ] **Step 7: Commit**

```bash
git add lib/iso_media/offsets.ex lib/iso_media.ex test/iso_media/offsets_test.exs
git commit -m "feat: fix_chunk_offsets with per-mdat delta remap and guards"
```

---

### Task 7: `co64` promotion + no-demotion latch (tests)

The promotion logic and latch already live in `Offsets` from Task 6. This task proves them with synthetic large-offset cases.

**Files:**
- Test: `test/iso_media/offsets_test.exs`

- [ ] **Step 1: Write the promotion tests**

Add to `test/iso_media/offsets_test.exs` (the helpers `build/1` and `stco_offsets/1` are already defined in the module from Task 6). A real >4 GB file is impractical to allocate, so we force promotion on a tiny file by lowering `:co64_threshold` — the promote/latch/resolve behavior is identical:

```elixir
  describe "co64 promotion" do
    test "promotes stco to co64 when an offset exceeds the threshold, chunks still resolve" do
      %{boxes: boxes, chunks: chunks} = build([<<10, 11>>, <<20, 21, 22>>])
      fixed = ISOMedia.Offsets.fix_chunk_offsets(boxes, co64_threshold: 5)

      co_box = ISOMedia.Box.find(fixed, ~w(moov co64))
      assert co_box != nil, "table should have been promoted to co64"
      co = ISOMedia.Boxes.ChunkOffset.decode(co_box)
      assert co.kind == :co64

      out = ISOMedia.serialize(fixed)

      chunks
      |> Enum.zip(co.offsets)
      |> Enum.each(fn {chunk, off} -> assert binary_part(out, off, byte_size(chunk)) == chunk end)
    end

    test "promotion converges and is idempotent (latched, never demoted)" do
      %{boxes: boxes} = build([<<1, 2>>, <<3, 4>>])
      once = ISOMedia.Offsets.fix_chunk_offsets(boxes, co64_threshold: 5)
      twice = ISOMedia.Offsets.fix_chunk_offsets(once, co64_threshold: 5)
      assert ISOMedia.serialize(twice) == ISOMedia.serialize(once)
      assert ISOMedia.Box.find(twice, ~w(moov co64)) != nil
    end
  end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/iso_media/offsets_test.exs`
Expected: PASS — promotion to `co64` works, converges, and is idempotent. (If idempotence fails, the fixpoint is compounding offsets or `rebase_mdats/1` is wrong — a bug in `Offsets`; fix there, do not weaken the test.)

- [ ] **Step 3: Commit**

```bash
git add test/iso_media/offsets_test.exs
git commit -m "test: cover stco->co64 promotion and fixpoint convergence"
```

---

### Task 8: `faststart` on a real file

**Files:**
- Test: `test/iso_media/offsets_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/offsets_test.exs`:

```elixir
  describe "faststart" do
    test "no-op when there is no moov or no mdat" do
      boxes = [%Box{type: "ftyp", data: <<0, 0, 0, 0>>}]
      assert ISOMedia.faststart(boxes) == boxes
    end

    test "moves moov before mdat and keeps every chunk resolvable on the real fixture" do
      original = File.read!(Path.join([__DIR__, "..", "fixtures", "sample.mp4"]))
      {:ok, boxes} = ISOMedia.parse(original)

      old_offsets =
        boxes |> ISOMedia.Box.find_all(~w(moov trak mdia minf stbl stco)) |> Enum.flat_map(fn b ->
          ISOMedia.Boxes.ChunkOffset.decode(b).offsets
        end)

      assert old_offsets != [], "fixture should have at least one stco entry"

      fixed = ISOMedia.faststart(boxes)
      out = ISOMedia.serialize(fixed)

      # moov now precedes mdat
      types = Enum.map(fixed, & &1.type)
      assert Enum.find_index(types, &(&1 == "moov")) < Enum.find_index(types, &(&1 == "mdat"))

      new_offsets =
        fixed |> ISOMedia.Box.find_all(~w(moov trak mdia minf stbl stco)) |> Enum.flat_map(fn b ->
          ISOMedia.Boxes.ChunkOffset.decode(b).offsets
        end)

      # Each chunk's bytes at the new offset match the bytes at the old offset in the
      # original file (first 16 bytes is enough to prove the offset points at the
      # same chunk data).
      Enum.zip(old_offsets, new_offsets)
      |> Enum.each(fn {old, new} ->
        k = min(16, byte_size(original) - old)
        assert binary_part(out, new, k) == binary_part(original, old, k)
      end)
    end
  end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/iso_media/offsets_test.exs`
Expected: PASS — `faststart` on `sample.mp4` keeps every chunk's bytes resolvable. (If the byte comparison fails, the remap is wrong on real data; debug `Offsets`/`Layout`, do not weaken the assertion. If the fixture happens to have `co64` not `stco`, change the `stco` path to `co64` in this test.)

- [ ] **Step 3: Commit**

```bash
git add test/iso_media/offsets_test.exs
git commit -m "test: faststart keeps chunks resolvable on real sample.mp4"
```

---

### Task 9: Verifiable MP4 builder for property tests

**Files:**
- Modify: `mix.exs`
- Create: `test/support/mp4_builder.ex`
- Test: `test/iso_media/mp4_builder_test.exs`

- [ ] **Step 1: Enable `test/support` compilation**

In `mix.exs`, add `elixirc_paths: elixirc_paths(Mix.env())` to the `project/0` keyword list (right after the `app:` line), and add these two private functions to the module:

```elixir
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
```

- [ ] **Step 2: Write the failing test**

Create `test/iso_media/mp4_builder_test.exs`:

```elixir
defmodule ISOMedia.MP4BuilderTest do
  use ExUnit.Case
  alias ISOMedia.Support.MP4Builder

  test "builds a parseable mp4 whose stco offsets point at the chunk bytes" do
    chunks = [<<1, 2, 3>>, <<4, 5>>, <<6>>]
    %{binary: bin, offsets: offsets} = MP4Builder.build(chunks)

    assert {:ok, boxes} = ISOMedia.parse(bin)
    assert ISOMedia.serialize(boxes) == bin

    stco = ISOMedia.Box.find(boxes, ~w(moov trak mdia minf stbl stco))
    assert ISOMedia.Boxes.ChunkOffset.decode(stco).offsets == offsets

    Enum.zip(chunks, offsets)
    |> Enum.each(fn {chunk, off} -> assert binary_part(bin, off, byte_size(chunk)) == chunk end)
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/iso_media/mp4_builder_test.exs`
Expected: FAIL — `ISOMedia.Support.MP4Builder.build/1 is undefined`.

- [ ] **Step 4: Write the builder**

Create `test/support/mp4_builder.ex`:

```elixir
defmodule ISOMedia.Support.MP4Builder do
  @moduledoc """
  Test helper: builds a minimal, structurally-real ISOBMFF binary with an `mdat`
  containing the given chunks (concatenated) and a `moov/trak/mdia/minf/stbl/stco`
  whose offsets point at each chunk's absolute file position. Returns the binary
  plus the expected offsets so tests can verify chunk resolution.
  """

  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  defp stco(offsets) do
    entries = for o <- offsets, into: <<>>, do: <<o::32>>
    leaf("stco", <<0, 0, 0, 0, length(offsets)::32, entries::binary>>)
  end

  # moov containing the real stbl path down to stco.
  defp moov(offsets) do
    stbl = container("stbl", stco(offsets))
    minf = container("minf", stbl)
    mdia = container("mdia", minf)
    trak = container("trak", mdia)
    container("moov", trak)
  end

  @doc """
  Build `%{binary: binary, offsets: [int], chunks: [binary], mdat_payload_start: int}`.
  """
  def build(chunks) when is_list(chunks) and chunks != [] do
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    mdat_payload = IO.iodata_to_binary(chunks)

    # moov byte length is independent of the offset *values* (fixed 32-bit entries),
    # so size it once with zeros, then place real offsets.
    zeros = List.duplicate(0, length(chunks))
    mdat_payload_start = byte_size(ftyp) + byte_size(moov(zeros)) + 8

    {offsets, _} =
      Enum.map_reduce(chunks, mdat_payload_start, fn c, pos -> {pos, pos + byte_size(c)} end)

    mdat = leaf("mdat", mdat_payload)
    binary = ftyp <> moov(offsets) <> mdat

    %{binary: binary, offsets: offsets, chunks: chunks, mdat_payload_start: mdat_payload_start}
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/iso_media/mp4_builder_test.exs`
Expected: PASS (1 test).

- [ ] **Step 6: Commit**

```bash
git add mix.exs test/support/mp4_builder.ex test/iso_media/mp4_builder_test.exs
git commit -m "test: add verifiable MP4 builder helper for property tests"
```

---

### Task 10: Property-based test suite (the centerpiece)

**Files:**
- Create: `test/iso_media/offsets_property_test.exs`

- [ ] **Step 1: Write the property test**

Create `test/iso_media/offsets_property_test.exs`:

```elixir
defmodule ISOMedia.OffsetsPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Box
  alias ISOMedia.Support.MP4Builder

  # A generated movie: 1..5 chunks of 1..8 random bytes each.
  defp movie do
    gen all chunks <- list_of(binary(min_length: 1, max_length: 8), min_length: 1, max_length: 5) do
      MP4Builder.build(chunks)
    end
  end

  # A structural edit applied to the top-level box list (never touches mdat bytes).
  defp edit do
    one_of([
      # insert a free box at a random top-level index
      tuple({constant(:insert_free), integer(0..3), integer(0..3)}),
      constant(:faststart)
    ])
  end

  defp apply_edit({:insert_free, size, where}, boxes) do
    free = %Box{type: "free", data: :binary.copy(<<0>>, size)}
    idx = rem(where, length(boxes) + 1)
    {:list, List.insert_at(boxes, idx, free)}
  end

  defp apply_edit(:faststart, boxes), do: {:faststart, ISOMedia.faststart(boxes)}

  # Returns the chunk offsets currently in the tree (document order).
  defp offsets(boxes) do
    boxes
    |> Box.find_all(~w(moov trak mdia minf stbl stco))
    |> Enum.flat_map(&ISOMedia.Boxes.ChunkOffset.decode(&1).offsets)
  end

  property "after any structural edits + fix, every chunk resolves to its original bytes" do
    check all %{binary: bin, chunks: chunks} <- movie(),
              edits <- list_of(edit(), max_length: 4) do
      {:ok, boxes} = ISOMedia.parse(bin)

      # Apply edits in sequence; :faststart already fixes offsets, otherwise fix at the end.
      {tag, edited} =
        Enum.reduce(edits, {:list, boxes}, fn e, {_t, acc} -> apply_edit(e, acc) end)

      fixed = if tag == :faststart, do: edited, else: ISOMedia.fix_chunk_offsets(edited)
      out = ISOMedia.serialize(fixed)

      chunks
      |> Enum.zip(offsets(fixed))
      |> Enum.each(fn {chunk, off} ->
        assert binary_part(out, off, byte_size(chunk)) == chunk,
               "chunk #{inspect(chunk)} not found at offset #{off}"
      end)
    end
  end

  property "no-op: fixing an unedited tree serializes identically to the input" do
    check all %{binary: bin} <- movie() do
      {:ok, boxes} = ISOMedia.parse(bin)
      assert ISOMedia.serialize(ISOMedia.fix_chunk_offsets(boxes)) == bin
    end
  end

  property "fix_chunk_offsets is idempotent" do
    check all %{binary: bin} <- movie(), pad <- integer(0..40) do
      {:ok, boxes} = ISOMedia.parse(bin)
      edited = List.insert_at(boxes, 1, %Box{type: "free", data: :binary.copy(<<0>>, pad)})
      once = ISOMedia.fix_chunk_offsets(edited)
      twice = ISOMedia.fix_chunk_offsets(once)
      assert ISOMedia.serialize(twice) == ISOMedia.serialize(once)
    end
  end

  property "round-trip is preserved (source_offset/size never leak into output)" do
    check all %{binary: bin} <- movie() do
      {:ok, boxes} = ISOMedia.parse(bin)
      assert ISOMedia.serialize(boxes) == bin
    end
  end
end
```

- [ ] **Step 2: Run the property suite**

Run: `mix test test/iso_media/offsets_property_test.exs`
Expected: PASS (4 properties). (Any failure here is a real correctness bug in `Offsets`/`Layout` — StreamData will shrink to a minimal counterexample; debug with `superpowers:systematic-debugging`, do not weaken the property.)

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS — everything green.

- [ ] **Step 4: Commit**

```bash
git add test/iso_media/offsets_property_test.exs
git commit -m "test: property-based chunk-resolution suite for offset fixing"
```

---

### Task 11: Docs — README + CLAUDE.md

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add faststart to the README**

In `README.md`, replace the `## Status` section with:

```markdown
## faststart

Move `moov` ahead of `mdat` so the file can start playing before it's fully
downloaded, with chunk offsets recomputed automatically:

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")
ISOMedia.write("movie.faststart.mp4", ISOMedia.faststart(boxes))
```

`ISOMedia.fix_chunk_offsets/1` is the underlying primitive: rearrange boxes however
you like, then call it to repair `stco`/`co64` (it auto-promotes `stco`→`co64` when
an offset exceeds 32 bits).

## Status

Phase 1: lossless tree surgery. Phase 2: `stco`/`co64` chunk-offset rewriting and
faststart. Offset fixing assumes `mdat` payloads are unchanged (box relocation, not
sample editing) and raises otherwise. **Large files:** the whole file is held in
memory, so faststart requires the file to fit in RAM; lazy/file-backed payloads are
a future phase. Fragmented MP4 and HEIF `iloc` offsets are out of scope.
See `docs/superpowers/specs/` for the designs.
```

- [ ] **Step 2: Update the architecture in CLAUDE.md**

In `CLAUDE.md`, in the `## Architecture` section, add these bullets to the module list (after the `ISOMedia.Boxes.*` bullet):

```markdown
- `ISOMedia.Layout` (`lib/iso_media/layout.ex`) — computes absolute box offsets for the current arrangement (`header_size/1`, `box_size/1`, `top_level_layout/1`); the basis for offset rewriting.
- `ISOMedia.Offsets` (`lib/iso_media/offsets.ex`) — `fix_chunk_offsets/1` (per-`mdat` delta remap of `stco`/`co64`, with latched `stco`→`co64` promotion via a layout fixpoint) and `faststart/1` (move `moov` before `mdat`, then fix). Exposed as `ISOMedia.fix_chunk_offsets/1` and `ISOMedia.faststart/1`.
- `ISOMedia.Boxes.ChunkOffset` — typed view for `stco`/`co64`.
```

And add this line at the end of the `## Architecture` section:

```markdown
Boxes carry `source_offset`/`source_size` (stamped by the parser) so offset rewriting knows where each `mdat` originally lived; these are metadata and never serialized.
```

- [ ] **Step 3: Verify compile + format**

Run: `mix compile --warnings-as-errors && mix format --check-formatted`
Expected: clean (run `mix format` first if needed).

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document faststart and offset rewriting"
```

---

## Self-Review Notes

- **Spec coverage:** `source_offset`+`source_size` on Box (T1), parser stamping (T2), `Layout` (T3), `Serializer.to_iodata`+iodata `write` for the memory win (T4), `Boxes.ChunkOffset` (T5), `fix_chunk_offsets` with per-mdat delta + integrity/unmappable guards (T6), `co64` promotion + no-demotion latch + fixpoint (implemented T6, proven T7), `faststart` incl. real-file test (T8), verifiable MP4 builder (T9), property suite — chunk-resolution, no-op, idempotence, round-trip-preserved (T10), docs incl. large-file limitation (T11). Out-of-scope items (fragmented, HEIF, sample editing, lazy payloads) intentionally excluded.
- **Type consistency:** `%ISOMedia.Box{...source_offset, source_size}` consistent T1→everywhere; `%ChunkOffset{kind, version, flags, offsets}` consistent T5→T6→T7→T8→T10; `Layout.header_size/1`/`box_size/1`/`top_level_layout/1` names consistent T3→T6; `fix_chunk_offsets/1`/`faststart/1` consistent T6→T11.
- **No-demotion latch:** the `promoted` MapSet in `walk_apply` only ever grows (via `MapSet.put`) and `kind` is `:co64` whenever the index is a member — never demoted within a run, satisfying the spec's convergence guarantee.
- **Idempotence:** `rebase_mdats/1` updates each `mdat`'s `source_offset` to its new position after fixing, so a second `fix_chunk_offsets` call computes delta 0 and is a no-op. The convergence loop uses the entry `source_offset` values throughout; rebasing happens once, after the loop settles.
- **Placeholders:** none — every code/test step contains complete content.
