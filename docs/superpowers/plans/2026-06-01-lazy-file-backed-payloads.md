# Lazy File-Backed Payloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `iso_media` parse, faststart, and write ISOBMFF files larger than RAM by representing big leaf payloads (`mdat`) as on-disk `%FileSlice{}` references that are streamed disk→disk instead of held in memory.

**Architecture:** A leaf box's `data` may be a `%ISOMedia.FileSlice{path, offset, length}`. A seeking `ISOMedia.LazyParser` reads only headers + small/container boxes (re-parsing each in-memory box through the existing `Parser` with an `:offset` base, so offsets stay absolute) and emits `FileSlice`s for ≥-threshold leaves. `Layout.box_size` is taught about `FileSlice` (so `faststart`/`fix_chunk_offsets` work unchanged), `Serializer` gains `materialize/1` + a streaming `stream/2`, and `ISOMedia.write/2` streams to disk in chunks.

**Tech Stack:** Elixir 1.19 / OTP 29, ExUnit, StreamData, `:file` raw I/O (`:file.pread/3`, `:file.write/2`).

**Branch:** `feat/lazy-payloads` (holds the approved spec at `docs/superpowers/specs/2026-05-31-lazy-file-backed-payloads-design.md`).

**Conventions for every commit:** end the message with:
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

**Raw-I/O rules (apply throughout):** open with `[:read, :binary, :raw]` / `[:write, :binary, :raw]`; a `:raw` fd is used only with the `:file` module (`:file.pread/3`, `:file.write/2`), never `IO.binread`/`IO.binwrite`; always use the `File.open(path, modes, fn io -> ... end)` callback form so the handle closes even if the body raises.

---

### Task 1: `ISOMedia.FileSlice`

**Files:**
- Create: `lib/iso_media/file_slice.ex`
- Test: `test/iso_media/file_slice_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/file_slice_test.exs`:

```elixir
defmodule ISOMedia.FileSliceTest do
  use ExUnit.Case
  alias ISOMedia.FileSlice

  setup do
    path = Path.join(System.tmp_dir!(), "iso_fs_#{System.unique_integer([:positive])}.bin")
    File.write!(path, <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "read/1 returns the exact byte range", %{path: path} do
    slice = %FileSlice{path: path, offset: 3, length: 4}
    assert FileSlice.read(slice) == <<3, 4, 5, 6>>
  end

  test "stream/3 writes the range to an io device in chunks", %{path: path} do
    out = Path.join(System.tmp_dir!(), "iso_fs_out_#{System.unique_integer([:positive])}.bin")
    on_exit(fn -> File.rm(out) end)
    slice = %FileSlice{path: path, offset: 2, length: 6}

    File.open!(out, [:write, :binary, :raw], fn io ->
      assert FileSlice.stream(slice, io, 2) == :ok
    end)

    assert File.read!(out) == <<2, 3, 4, 5, 6, 7>>
  end

  test "read/1 raises with context on an out-of-range read", %{path: path} do
    slice = %FileSlice{path: path, offset: 8, length: 100}
    assert_raise RuntimeError, ~r/FileSlice/, fn -> FileSlice.read(slice) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/file_slice_test.exs`
Expected: FAIL — `ISOMedia.FileSlice.__struct__/1 is undefined`.

- [ ] **Step 3: Write the implementation**

Create `lib/iso_media/file_slice.ex`:

```elixir
defmodule ISOMedia.FileSlice do
  @moduledoc """
  An inert reference to a byte range on disk: `%FileSlice{path, offset, length}`.

  A leaf box may carry a `FileSlice` as its `data` instead of an in-memory binary,
  so bulk payloads (notably `mdat`) are never loaded into memory. The bytes are read
  or streamed on demand; nothing here holds an open file handle.
  """

  defstruct [:path, :offset, :length]

  @type t :: %__MODULE__{
          path: Path.t(),
          offset: non_neg_integer(),
          length: non_neg_integer()
        }

  @doc "Read the slice's bytes into a binary (opens, preads, closes)."
  def read(%__MODULE__{path: path, offset: offset, length: length}) do
    File.open!(path, [:read, :binary, :raw], fn io ->
      case :file.pread(io, offset, length) do
        {:ok, data} when byte_size(data) == length ->
          data

        {:ok, data} ->
          raise "FileSlice.read: short read at #{offset} of #{path}: wanted #{length}, got #{byte_size(data)}"

        :eof ->
          raise "FileSlice.read: unexpected EOF reading #{length} bytes at #{offset} of #{path}"

        {:error, reason} ->
          raise "FileSlice.read: #{:file.format_error(reason)} reading #{length} bytes at #{offset} of #{path}"
      end
    end)
  end

  @doc """
  Stream the slice's bytes to an already-open (raw) `io_device` in `chunk_size`
  chunks. The source is opened once (callback form, so it closes even if a write
  raises) and read sequentially.
  """
  def stream(%__MODULE__{path: path, offset: offset, length: length}, io_device, chunk_size \\ 65_536) do
    File.open!(path, [:read, :binary, :raw], fn src ->
      stream_chunks(src, io_device, path, offset, length, chunk_size)
    end)
  end

  defp stream_chunks(_src, _dest, _path, _offset, 0, _chunk), do: :ok

  defp stream_chunks(src, dest, path, offset, remaining, chunk) do
    n = min(remaining, chunk)

    case :file.pread(src, offset, n) do
      {:ok, data} when byte_size(data) == n ->
        case :file.write(dest, data) do
          :ok -> stream_chunks(src, dest, path, offset + n, remaining - n, chunk)
          {:error, reason} -> raise "FileSlice.stream: write failed: #{:file.format_error(reason)}"
        end

      {:ok, data} ->
        raise "FileSlice.stream: short read at #{offset} of #{path}: wanted #{n}, got #{byte_size(data)}"

      :eof ->
        raise "FileSlice.stream: unexpected EOF at #{offset} of #{path}"

      {:error, reason} ->
        raise "FileSlice.stream: #{:file.format_error(reason)} at #{offset} of #{path}"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/file_slice_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/file_slice.ex test/iso_media/file_slice_test.exs
git commit -m "feat: add FileSlice on-disk payload reference"
```

---

### Task 2: `Parser` gains an `:offset` option

**Files:**
- Modify: `lib/iso_media/parser.ex`
- Test: `test/iso_media/parser_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/parser_test.exs`:

```elixir
  test "the :offset option stamps absolute source_offsets" do
    inner = <<8::32, "mvhd", 8::32, "free">>
    moov = <<8 + byte_size(inner)::32, "moov", inner::binary>>

    assert {:ok, [moov_box]} = Parser.parse(moov, offset: 100)
    assert moov_box.source_offset == 100
    [mvhd, free] = moov_box.children
    assert mvhd.source_offset == 108
    assert free.source_offset == 116
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/parser_test.exs`
Expected: FAIL — `moov_box.source_offset` is `0`, not `100`.

- [ ] **Step 3: Thread the base offset**

In `lib/iso_media/parser.ex`, replace the 2-arity `parse_boxes/2` delegating clause:

```elixir
  defp parse_boxes(binary, opts), do: parse_boxes(binary, opts, 0)
```

with:

```elixir
  defp parse_boxes(binary, opts), do: parse_boxes(binary, opts, Keyword.get(opts, :offset, 0))
```

Also document the option in `parse/2`'s `@doc` (append to the existing Options list):

```
    * `:offset` (default `0`) — absolute byte offset the binary begins at; threaded
      into every box's `source_offset` so they are absolute even when parsing a slice.
```

(Everything else in the parser is unchanged; the 3-arity `parse_boxes/3` already threads and recurses correctly.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/parser_test.exs`
Expected: PASS (the new test + all existing parser tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/parser.ex test/iso_media/parser_test.exs
git commit -m "feat: add :offset base option to Parser for absolute offsets"
```

---

### Task 3: `Layout.box_size/1` handles `FileSlice`

**Files:**
- Modify: `lib/iso_media/layout.ex`
- Test: `test/iso_media/layout_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/layout_test.exs`:

```elixir
  test "box_size counts a FileSlice payload by its length" do
    slice = %ISOMedia.FileSlice{path: "irrelevant", offset: 0, length: 5000}
    box = %Box{type: "mdat", data: slice}
    # compact header (8) + slice length (5000)
    assert Layout.box_size(box) == 5008
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/layout_test.exs`
Expected: FAIL — `byte_size/1` raises on a `%FileSlice{}` (ArgumentError / FunctionClauseError).

- [ ] **Step 3: Add the clause**

In `lib/iso_media/layout.ex`, add an alias and a new `box_size/1` clause **before** the existing `data: nil` and binary clauses. Add near the top, after `alias ISOMedia.Box`:

```elixir
  alias ISOMedia.FileSlice
```

Then add as the first `box_size/1` clause:

```elixir
  def box_size(%Box{data: %FileSlice{length: len}} = box), do: header_size(box) + len
```

(Leave the existing `box_size(%Box{data: nil, children: ...})` and `box_size(%Box{data: data})` clauses unchanged, after this one.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/layout_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/layout.ex test/iso_media/layout_test.exs
git commit -m "feat: Layout.box_size handles FileSlice payloads"
```

---

### Task 4: `Box.read_data/1`

**Files:**
- Modify: `lib/iso_media/box.ex`
- Test: `test/iso_media/box_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/box_test.exs`:

```elixir
  describe "read_data/1" do
    test "returns the binary for an in-memory leaf" do
      assert Box.read_data(%Box{type: "free", data: <<1, 2, 3>>}) == <<1, 2, 3>>
    end

    test "returns nil for a container" do
      assert Box.read_data(%Box{type: "moov", data: nil, children: []}) == nil
    end

    test "reads the bytes for a FileSlice leaf" do
      path = Path.join(System.tmp_dir!(), "iso_box_rd_#{System.unique_integer([:positive])}.bin")
      File.write!(path, <<9, 8, 7, 6, 5>>)
      on_exit(fn -> File.rm(path) end)
      box = %Box{type: "mdat", data: %ISOMedia.FileSlice{path: path, offset: 1, length: 3}}
      assert Box.read_data(box) == <<8, 7, 6>>
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/box_test.exs`
Expected: FAIL — `ISOMedia.Box.read_data/1 is undefined`.

- [ ] **Step 3: Write the implementation**

In `lib/iso_media/box.ex`, add (before the final `end`):

```elixir
  @doc """
  Return a leaf box's payload bytes, reading the file if it's a `FileSlice`.
  Returns `nil` for a container.
  """
  def read_data(%__MODULE__{data: %ISOMedia.FileSlice{} = slice}), do: ISOMedia.FileSlice.read(slice)
  def read_data(%__MODULE__{data: data}), do: data
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/box_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/box.ex test/iso_media/box_test.exs
git commit -m "feat: add Box.read_data/1 (materializes FileSlice leaves)"
```

---

### Task 5: `Serializer.materialize/1` + `serialize/1` routing + `to_iodata` guard

**Files:**
- Modify: `lib/iso_media/serializer.ex`
- Test: `test/iso_media/serializer_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/serializer_test.exs`:

```elixir
  describe "FileSlice handling" do
    setup do
      path = Path.join(System.tmp_dir!(), "iso_ser_#{System.unique_integer([:positive])}.bin")
      File.write!(path, <<10, 11, 12, 13>>)
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "materialize/1 replaces a FileSlice leaf with its bytes", %{path: path} do
      box = %ISOMedia.Box{type: "mdat", data: %ISOMedia.FileSlice{path: path, offset: 0, length: 4}}
      [materialized] = ISOMedia.Serializer.materialize([box])
      assert materialized.data == <<10, 11, 12, 13>>
    end

    test "serialize/1 materializes a lazy tree to the right bytes", %{path: path} do
      box = %ISOMedia.Box{type: "mdat", data: %ISOMedia.FileSlice{path: path, offset: 0, length: 4}}
      # size 12 (8 header + 4 payload), type mdat, then the 4 bytes
      assert ISOMedia.Serializer.serialize([box]) == <<12::32, "mdat", 10, 11, 12, 13>>
    end

    test "to_iodata/1 raises a clear error on an un-materialized FileSlice", %{path: path} do
      box = %ISOMedia.Box{type: "mdat", data: %ISOMedia.FileSlice{path: path, offset: 0, length: 4}}
      assert_raise ArgumentError, ~r/FileSlice/, fn -> ISOMedia.Serializer.to_iodata([box]) end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: FAIL — `ISOMedia.Serializer.materialize/1 is undefined`.

- [ ] **Step 3: Write the implementation**

In `lib/iso_media/serializer.ex`:

(a) add an alias after `alias ISOMedia.Box`:

```elixir
  alias ISOMedia.FileSlice
```

(b) replace the `serialize/1` clause with one that materializes first:

```elixir
  @doc "Serialize a box or list of boxes to a binary (materializes any FileSlice payloads)."
  def serialize(boxes), do: boxes |> materialize() |> to_iodata() |> IO.iodata_to_binary()
```

(c) add `materialize/1` (after `serialize/1`):

```elixir
  @doc "Replace every FileSlice leaf payload in the tree with its on-disk bytes."
  def materialize(%Box{} = box), do: materialize_box(box)
  def materialize(boxes) when is_list(boxes), do: Enum.map(boxes, &materialize_box/1)

  defp materialize_box(%Box{data: %FileSlice{} = slice} = box), do: %{box | data: FileSlice.read(slice)}

  defp materialize_box(%Box{data: nil, children: children} = box),
    do: %{box | children: Enum.map(children, &materialize_box/1)}

  defp materialize_box(%Box{} = box), do: box
```

(d) add a `FileSlice` clause to `encode_payload/1`, placed **after** the existing mixed-box guard and `data: nil` clause but **before** the binary `data` clause:

```elixir
  defp encode_payload(%Box{data: %FileSlice{}}) do
    raise ArgumentError,
          "box payload is an unread FileSlice; use ISOMedia.write/2 to stream it, " <>
            "or ISOMedia.serialize/1 to materialize it into memory"
  end
```

So the `encode_payload/1` clause order becomes: mixed-box guard → `data: nil` → `%FileSlice{}` raise → binary `data`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite (no regression)**

Run: `mix test`
Expected: PASS — `serialize/1` still produces identical bytes for in-memory trees (materialize is a no-op when there are no slices).

- [ ] **Step 6: Commit**

```bash
git add lib/iso_media/serializer.ex test/iso_media/serializer_test.exs
git commit -m "feat: Serializer materialize/1 and FileSlice guard in to_iodata"
```

---

### Task 6: `Serializer.stream/3` (streaming writer)

**Files:**
- Modify: `lib/iso_media/serializer.ex`
- Test: `test/iso_media/serializer_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/serializer_test.exs`:

```elixir
  describe "stream/3" do
    test "streams an in-memory tree byte-identically to serialize/1" do
      boxes = [
        %ISOMedia.Box{type: "ftyp", data: <<"isom", 0::32, "isom">>},
        %ISOMedia.Box{type: "moov", children: [%ISOMedia.Box{type: "mvhd", data: <<0, 1, 2>>}]},
        %ISOMedia.Box{type: "mdat", data: <<9, 9, 9, 9>>}
      ]

      out = Path.join(System.tmp_dir!(), "iso_stream_#{System.unique_integer([:positive])}.bin")
      on_exit(fn -> File.rm(out) end)
      File.open!(out, [:write, :binary, :raw], fn io -> :ok = ISOMedia.Serializer.stream(boxes, io) end)

      assert File.read!(out) == ISOMedia.Serializer.serialize(boxes)
    end

    test "streams a FileSlice leaf from disk" do
      src = Path.join(System.tmp_dir!(), "iso_stream_src_#{System.unique_integer([:positive])}.bin")
      File.write!(src, <<7, 7, 7, 7, 7, 7>>)
      out = Path.join(System.tmp_dir!(), "iso_stream_out_#{System.unique_integer([:positive])}.bin")
      on_exit(fn -> File.rm(src); File.rm(out) end)

      box = %ISOMedia.Box{type: "mdat", data: %ISOMedia.FileSlice{path: src, offset: 1, length: 4}}
      File.open!(out, [:write, :binary, :raw], fn io -> ISOMedia.Serializer.stream([box], io, 2) end)

      # size 12 (8 + 4), type mdat, then bytes src[1..4]
      assert File.read!(out) == <<12::32, "mdat", 7, 7, 7, 7>>
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: FAIL — `ISOMedia.Serializer.stream/2 is undefined` (default arg makes `stream/2` and `stream/3`).

- [ ] **Step 3: Write the implementation**

In `lib/iso_media/serializer.ex`, add an alias for Layout near the top:

```elixir
  alias ISOMedia.Layout
```

and add the streaming functions (after `to_iodata/1`):

```elixir
  @doc """
  Stream a box or list of boxes to an open raw `io_device`, reading `FileSlice`
  payloads from disk in `chunk_size`-byte chunks (so a multi-GB payload is never
  held in memory). Returns `:ok`.
  """
  def stream(boxes, io_device, chunk_size \\ 65_536)
  def stream(%Box{} = box, io_device, chunk_size), do: stream([box], io_device, chunk_size)

  def stream(boxes, io_device, chunk_size) when is_list(boxes) do
    Enum.each(boxes, &stream_box(&1, io_device, chunk_size))
  end

  defp stream_box(%Box{data: data, children: [_ | _]}, _io, _chunk) when not is_nil(data) do
    raise ArgumentError, "invalid box: has both data and children (cannot serialize unambiguously)"
  end

  defp stream_box(%Box{} = box, io, chunk_size) do
    uuid = box.uuid || <<>>
    # body = uuid ++ payload; body length is derivable from Layout without reading.
    body_len = byte_size(uuid) + (Layout.box_size(box) - Layout.header_size(box))
    write!(io, encode_header(box, body_len))
    write!(io, uuid)
    stream_payload(box, io, chunk_size)
  end

  defp stream_payload(%Box{data: %FileSlice{} = slice}, io, chunk), do: FileSlice.stream(slice, io, chunk)

  defp stream_payload(%Box{data: nil, children: children}, io, chunk),
    do: Enum.each(children, &stream_box(&1, io, chunk))

  defp stream_payload(%Box{data: data}, io, _chunk) when is_binary(data), do: write!(io, data)

  defp write!(io, data) do
    case :file.write(io, data) do
      :ok -> :ok
      {:error, reason} -> raise "Serializer.stream: write failed: #{:file.format_error(reason)}"
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/serializer.ex test/iso_media/serializer_test.exs
git commit -m "feat: streaming Serializer.stream/3 for FileSlice-backed trees"
```

---

### Task 7: `ISOMedia.LazyParser`

**Files:**
- Create: `lib/iso_media/lazy_parser.ex`
- Test: `test/iso_media/lazy_parser_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/lazy_parser_test.exs`:

```elixir
defmodule ISOMedia.LazyParserTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FileSlice, LazyParser}

  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  setup do
    # ftyp (small leaf) + moov (container w/ small mvhd) + mdat (big leaf)
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    moov = container("moov", leaf("mvhd", <<0, 1, 2, 3>>))
    big = :binary.copy(<<7>>, 5000)
    mdat = leaf("mdat", big)
    bin = ftyp <> moov <> mdat

    path = Path.join(System.tmp_dir!(), "iso_lazy_#{System.unique_integer([:positive])}.mp4")
    File.write!(path, bin)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path, bin: bin, big: big, ftyp: ftyp, moov: moov}
  end

  test "big leaf becomes a FileSlice; small leaf and container stay in memory", ctx do
    assert {:ok, boxes} = LazyParser.parse_file(ctx.path, lazy_threshold: 1000)
    [ftyp_box, moov_box, mdat_box] = boxes

    assert is_binary(ftyp_box.data)
    assert ftyp_box.type == "ftyp"

    assert moov_box.data == nil
    assert [%Box{type: "mvhd", data: <<0, 1, 2, 3>>}] = moov_box.children

    assert %FileSlice{path: p, length: 5000} = mdat_box.data
    assert p == ctx.path
    assert FileSlice.read(mdat_box.data) == ctx.big
  end

  test "source_offset/source_size match the eager parser (incl. nested)", ctx do
    {:ok, lazy} = LazyParser.parse_file(ctx.path, lazy_threshold: 1000)
    {:ok, eager} = ISOMedia.parse(ctx.bin)

    offsets = fn boxes ->
      Enum.map(boxes, fn b ->
        {b.type, b.source_offset, b.source_size, Enum.map(b.children, &{&1.type, &1.source_offset})}
      end)
    end

    assert offsets.(lazy) == offsets.(eager)
  end

  test "serialize of a lazy tree equals the original bytes", ctx do
    {:ok, boxes} = LazyParser.parse_file(ctx.path, lazy_threshold: 1000)
    assert ISOMedia.Serializer.serialize(boxes) == ctx.bin
  end

  test "a size-0 (eof) mdat resolves its length from the file size" do
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    big = :binary.copy(<<3>>, 2000)
    # size field 0 → runs to EOF
    eof_mdat = <<0::32, "mdat", big::binary>>
    bin = ftyp <> eof_mdat
    path = Path.join(System.tmp_dir!(), "iso_lazy_eof_#{System.unique_integer([:positive])}.mp4")
    File.write!(path, bin)
    on_exit(fn -> File.rm(path) end)

    {:ok, boxes} = LazyParser.parse_file(path, lazy_threshold: 1000)
    [_ftyp, mdat_box] = boxes
    assert mdat_box.size_mode == :eof
    assert %FileSlice{length: 2000} = mdat_box.data
    # round-trips byte-for-byte (the size-0 box re-emits size field 0)
    assert ISOMedia.Serializer.serialize(boxes) == bin
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/lazy_parser_test.exs`
Expected: FAIL — `ISOMedia.LazyParser.parse_file/2 is undefined`.

- [ ] **Step 3: Write the implementation**

Create `lib/iso_media/lazy_parser.ex`:

```elixir
defmodule ISOMedia.LazyParser do
  @moduledoc """
  Parses an ISOBMFF file without loading it entirely into memory.

  Walks the top-level boxes by seeking. Any box that is read into memory (a
  container, or a leaf smaller than the threshold) is parsed by re-running the
  in-memory `ISOMedia.Parser` over its exact bytes with `offset:` set, so its
  structure and absolute `source_offset`s match the eager parser. A leaf payload at
  or above `:lazy_threshold` becomes an `ISOMedia.FileSlice` and is never read.
  """

  alias ISOMedia.{Box, FileSlice, Parser, Registry}

  @default_threshold 1_048_576

  @doc """
  Parse `path` lazily into `{:ok, [%Box{}]}` | `{:error, reason}`.

  Options: `:lazy_threshold` (default #{@default_threshold}), `:heuristic`
  (default `false`, applies only to boxes small enough to be read).
  """
  def parse_file(path, opts \\ []) do
    threshold = Keyword.get(opts, :lazy_threshold, @default_threshold)
    heuristic = Keyword.get(opts, :heuristic, false)
    file_size = File.stat!(path).size

    boxes =
      File.open!(path, [:read, :binary, :raw], fn io ->
        parse_level(io, path, 0, file_size, threshold, heuristic)
      end)

    {:ok, boxes}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_level(_io, _path, pos, file_size, _threshold, _heuristic) when pos >= file_size, do: []

  defp parse_level(io, path, pos, file_size, threshold, heuristic) do
    {box, next} = parse_one(io, path, pos, file_size, threshold, heuristic)
    [box | parse_level(io, path, next, file_size, threshold, heuristic)]
  end

  defp parse_one(io, path, pos, file_size, threshold, heuristic) do
    <<size::32, type::binary-size(4)>> = pread!(io, pos, 8)
    {size_mode, header_len, total_size} = resolve_size(io, pos, size, file_size)
    uuid_len = if type == "uuid", do: 16, else: 0
    payload_length = total_size - header_len - uuid_len

    box =
      cond do
        Registry.container?(type) ->
          reparse(io, pos, total_size, heuristic)

        payload_length >= threshold ->
          file_slice_box(io, path, type, size_mode, pos, header_len, uuid_len, payload_length, total_size)

        true ->
          reparse(io, pos, total_size, heuristic)
      end

    {box, pos + total_size}
  end

  # Re-parse a fully-read box's bytes through the in-memory parser so its structure
  # and absolute offsets are identical to the eager path.
  defp reparse(io, pos, total_size, heuristic) do
    full = pread!(io, pos, total_size)
    {:ok, [box]} = Parser.parse(full, offset: pos, heuristic: heuristic)
    box
  end

  defp file_slice_box(io, path, type, size_mode, pos, header_len, uuid_len, payload_length, total_size) do
    uuid = if uuid_len == 16, do: pread!(io, pos + header_len, 16), else: nil
    payload_offset = pos + header_len + uuid_len

    %Box{
      type: type,
      data: %FileSlice{path: path, offset: payload_offset, length: payload_length},
      children: [],
      uuid: uuid,
      size_mode: size_mode,
      source_offset: pos,
      source_size: total_size
    }
  end

  defp resolve_size(_io, pos, 0, file_size), do: {:eof, 8, file_size - pos}

  defp resolve_size(io, pos, 1, _file_size) do
    <<largesize::64>> = pread!(io, pos + 8, 8)
    {:large, 16, largesize}
  end

  defp resolve_size(_io, _pos, size, _file_size), do: {:compact, 8, size}

  defp pread!(io, offset, length) do
    case :file.pread(io, offset, length) do
      {:ok, data} when byte_size(data) == length ->
        data

      {:ok, data} ->
        raise "LazyParser: short read at #{offset}: wanted #{length}, got #{byte_size(data)}"

      :eof ->
        raise "LazyParser: unexpected EOF at #{offset} (wanted #{length} bytes)"

      {:error, reason} ->
        raise "LazyParser: #{:file.format_error(reason)} at #{offset}"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/lazy_parser_test.exs`
Expected: PASS (4 tests). (If the offsets test fails, the `:offset` threading in Task 2 or the `reparse` call is wrong — debug there, do not weaken the assertion.)

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/lazy_parser.ex test/iso_media/lazy_parser_test.exs
git commit -m "feat: seeking LazyParser for file-backed payloads"
```

---

### Task 8: `ISOMedia.read/2` `:lazy` + streaming `write/2` + overwrite guard

**Files:**
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media_test.exs`:

```elixir
  describe "lazy read + streaming write" do
    setup do
      ftyp = <<16::32, "ftyp", "isom", 0::32>>
      big = :binary.copy(<<5>>, 4000)
      mdat = <<8 + byte_size(big)::32, "mdat", big::binary>>
      bin = ftyp <> mdat
      src = Path.join(System.tmp_dir!(), "iso_lw_src_#{System.unique_integer([:positive])}.mp4")
      File.write!(src, bin)
      on_exit(fn -> File.rm(src) end)
      {:ok, src: src, bin: bin}
    end

    test "read(lazy: true) keeps mdat as a FileSlice", %{src: src} do
      assert {:ok, boxes} = ISOMedia.read(src, lazy: true, lazy_threshold: 1000)
      mdat = ISOMedia.Box.find(boxes, ~w(mdat))
      assert %ISOMedia.FileSlice{} = mdat.data
    end

    test "write/2 streams a lazy tree byte-identically", %{src: src, bin: bin} do
      {:ok, boxes} = ISOMedia.read(src, lazy: true, lazy_threshold: 1000)
      out = Path.join(System.tmp_dir!(), "iso_lw_out_#{System.unique_integer([:positive])}.mp4")
      on_exit(fn -> File.rm(out) end)
      assert :ok = ISOMedia.write(out, boxes)
      assert File.read!(out) == bin
    end

    test "write/2 refuses to overwrite a FileSlice source", %{src: src} do
      {:ok, boxes} = ISOMedia.read(src, lazy: true, lazy_threshold: 1000)
      assert_raise ArgumentError, ~r/FileSlice source/, fn -> ISOMedia.write(src, boxes) end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media_test.exs`
Expected: FAIL — `read/2` ignores `:lazy` (returns an eager tree with a binary, not a `FileSlice`).

- [ ] **Step 3: Update the public API**

In `lib/iso_media.ex`, replace `read/2` and `write/2`:

```elixir
  @doc """
  Read a file and parse it. Pass `lazy: true` to keep large leaf payloads
  (≥ `:lazy_threshold`, default 1 MB) as `ISOMedia.FileSlice` references instead of
  loading them, so files larger than memory can be processed.
  """
  def read(path, opts \\ []) do
    if Keyword.get(opts, :lazy, false) do
      ISOMedia.LazyParser.parse_file(path, opts)
    else
      with {:ok, binary} <- File.read(path), do: parse(binary, opts)
    end
  end

  @doc """
  Serialize boxes and write them to `path`, streaming any `FileSlice` payloads
  disk→disk (memory-safe for large files). Raises if `path` is one of the tree's
  `FileSlice` sources (you cannot stream-overwrite the file you are reading).
  """
  def write(path, boxes) do
    check_overwrite!(path, boxes)

    case File.open(path, [:write, :binary, :raw], fn io -> ISOMedia.Serializer.stream(boxes, io) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_overwrite!(path, boxes) do
    out_expanded = Path.expand(path)
    out_id = file_id(path)

    boxes
    |> collect_slice_paths()
    |> Enum.uniq()
    |> Enum.each(fn src ->
      cond do
        Path.expand(src) == out_expanded ->
          raise ArgumentError, "write/2: output #{path} is also a FileSlice source; write to a different file"

        out_id != nil and out_id == file_id(src) ->
          raise ArgumentError,
                "write/2: output #{path} resolves to the same file as a FileSlice source (#{src}); write to a different file"

        true ->
          :ok
      end
    end)
  end

  defp file_id(path) do
    case File.stat(path) do
      {:ok, %File.Stat{major_device: maj, minor_device: min, inode: ino}} -> {maj, min, ino}
      _ -> nil
    end
  end

  defp collect_slice_paths(boxes) when is_list(boxes), do: Enum.flat_map(boxes, &collect_slice_paths/1)
  defp collect_slice_paths(%ISOMedia.Box{data: %ISOMedia.FileSlice{path: p}}), do: [p]
  defp collect_slice_paths(%ISOMedia.Box{data: nil, children: children}), do: collect_slice_paths(children)
  defp collect_slice_paths(%ISOMedia.Box{}), do: []
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full suite (no regression)**

Run: `mix test`
Expected: PASS — eager `read/2` unchanged; `write/2` on in-memory trees still writes identical bytes and returns `:ok`.

- [ ] **Step 6: Commit**

```bash
git add lib/iso_media.ex test/iso_media_test.exs
git commit -m "feat: ISOMedia.read lazy option and streaming write/2 with overwrite guard"
```

---

### Task 9: Integration + property tests (the headline)

**Files:**
- Create: `test/iso_media/lazy_roundtrip_test.exs`
- Create: `test/iso_media/lazy_property_test.exs`

- [ ] **Step 1: Write the integration test (real fixture)**

Create `test/iso_media/lazy_roundtrip_test.exs`:

```elixir
defmodule ISOMedia.LazyRoundtripTest do
  use ExUnit.Case

  @fixture Path.join([__DIR__, "..", "fixtures", "sample.mp4"])

  defp tmp(name), do: Path.join(System.tmp_dir!(), "#{name}_#{System.unique_integer([:positive])}.mp4")

  test "lazy parse + serialize == eager parse + serialize == original bytes" do
    original = File.read!(@fixture)
    {:ok, eager} = ISOMedia.read(@fixture)
    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)

    assert ISOMedia.Serializer.serialize(eager) == original
    assert ISOMedia.Serializer.serialize(lazy) == original
  end

  test "streaming write of a lazy tree reproduces the file" do
    out = tmp("lazy_write")
    on_exit(fn -> File.rm(out) end)
    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    assert :ok = ISOMedia.write(out, lazy)
    assert File.read!(out) == File.read!(@fixture)
  end

  test "faststart a lazy tree without materializing mdat, then stream it out" do
    out = tmp("lazy_faststart")
    on_exit(fn -> File.rm(out) end)

    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    fixed = ISOMedia.faststart(lazy)

    # mdat is still a FileSlice (never read into memory)
    assert %ISOMedia.FileSlice{} = ISOMedia.Box.find(fixed, ~w(mdat)).data

    assert :ok = ISOMedia.write(out, fixed)

    # The written file is valid: moov precedes mdat and chunks resolve.
    {:ok, reparsed} = ISOMedia.read(out)
    types = Enum.map(reparsed, & &1.type)
    assert Enum.find_index(types, &(&1 == "moov")) < Enum.find_index(types, &(&1 == "mdat"))

    original = File.read!(@fixture)
    out_bin = File.read!(out)

    old_offsets =
      (with {:ok, e} <- ISOMedia.read(@fixture),
            do: e)
      |> ISOMedia.Box.find_all(~w(moov trak mdia minf stbl stco))
      |> Enum.flat_map(&ISOMedia.Boxes.ChunkOffset.decode(&1).offsets)

    new_offsets =
      reparsed
      |> ISOMedia.Box.find_all(~w(moov trak mdia minf stbl stco))
      |> Enum.flat_map(&ISOMedia.Boxes.ChunkOffset.decode(&1).offsets)

    assert length(old_offsets) == length(new_offsets)

    Enum.zip(old_offsets, new_offsets)
    |> Enum.each(fn {old, new} ->
      k = min(16, byte_size(original) - old)
      assert binary_part(out_bin, new, k) == binary_part(original, old, k)
    end)
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/iso_media/lazy_roundtrip_test.exs`
Expected: PASS (3 tests). (If the faststart test fails, the lazy/streaming path diverges from eager — debug `LazyParser`/`Serializer.stream`/`Layout`, do not weaken assertions.)

- [ ] **Step 3: Write the property test**

Create `test/iso_media/lazy_property_test.exs`:

```elixir
defmodule ISOMedia.LazyPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Support.MP4Builder

  defp movie do
    gen all(chunks <- list_of(binary(min_length: 1, max_length: 16), min_length: 1, max_length: 5)) do
      MP4Builder.build(chunks)
    end
  end

  defp tmp, do: Path.join(System.tmp_dir!(), "iso_lp_#{System.unique_integer([:positive])}.mp4")

  property "lazy and eager parses serialize to the same original bytes" do
    check all(%{binary: bin} <- movie()) do
      path = tmp()
      File.write!(path, bin)

      try do
        {:ok, eager} = ISOMedia.read(path)
        {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)
        assert ISOMedia.Serializer.serialize(eager) == bin
        assert ISOMedia.Serializer.serialize(lazy) == bin
      after
        File.rm(path)
      end
    end
  end

  property "lazy faststart + streaming write == eager faststart + serialize" do
    check all(%{binary: bin} <- movie()) do
      path = tmp()
      out = tmp()
      File.write!(path, bin)

      try do
        {:ok, eager} = ISOMedia.read(path)
        eager_bytes = eager |> ISOMedia.faststart() |> ISOMedia.Serializer.serialize()

        {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)
        :ok = ISOMedia.write(out, ISOMedia.faststart(lazy))

        assert File.read!(out) == eager_bytes
      after
        File.rm(path)
        File.rm(out)
      end
    end
  end
end
```

- [ ] **Step 4: Run the property suite + full suite**

Run: `mix test test/iso_media/lazy_property_test.exs && mix test`
Expected: PASS — all properties and the whole suite green. (A property failure is a real bug in the lazy/streaming path; StreamData shrinks to a minimal counterexample — debug, don't weaken.)

- [ ] **Step 5: Commit**

```bash
git add test/iso_media/lazy_roundtrip_test.exs test/iso_media/lazy_property_test.exs
git commit -m "test: lazy roundtrip + faststart integration and property suites"
```

---

### Task 10: Docs

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a large-files section to the README**

In `README.md`, replace the `## Status` section with:

```markdown
## Large files (lazy payloads)

Process files bigger than RAM: parse keeps big leaf payloads (`mdat`) as on-disk
references, and `write/2` streams them disk→disk.

```elixir
{:ok, boxes} = ISOMedia.read("huge.mp4", lazy: true)   # mdat stays on disk
ISOMedia.write("huge.faststart.mp4", ISOMedia.faststart(boxes))  # streamed out
```

Peak memory is roughly the metadata (`moov`) plus one stream chunk, independent of
file size. `serialize/1` instead reads slices into memory (use it only for small
trees). You must not `write/2` to a file you're reading from (it raises). The source
file must stay put until the write completes.

## Status

Phase 1: lossless tree surgery. Phase 2: `stco`/`co64` chunk-offset rewriting and
faststart. Phase 3: lazy file-backed payloads for files larger than memory. Offset
fixing assumes `mdat` payloads are unchanged (box relocation, not sample editing).
Fragmented MP4 and HEIF `iloc` offsets remain out of scope. See
`docs/superpowers/specs/` for the designs.
```

- [ ] **Step 2: Update CLAUDE.md architecture**

In `CLAUDE.md`, add these bullets to the module list in `## Architecture` (after the `ISOMedia.Offsets` bullet):

```markdown
- `ISOMedia.FileSlice` (`lib/iso_media/file_slice.ex`) — an inert `{path, offset, length}` reference; a leaf's `data` may be a `FileSlice` instead of a binary so bulk payloads stay on disk. `read/1` and `stream/3` (raw `:file` I/O, leak-safe callback opens).
- `ISOMedia.LazyParser` (`lib/iso_media/lazy_parser.ex`) — `parse_file/2`: seeks the top-level boxes, re-parsing each in-memory box through `Parser` with `offset:` (absolute offsets), emitting a `FileSlice` for any leaf ≥ `:lazy_threshold`. Reached via `ISOMedia.read(path, lazy: true)`.
```

And update the `ISOMedia.Serializer` and `ISOMedia` lines to mention `materialize/1`/`stream/3` and that `write/2` streams (so `FileSlice` trees never fully materialize).

- [ ] **Step 3: Verify compile + format**

Run: `mix compile --warnings-as-errors && mix format --check-formatted`
Expected: clean (run `mix format` first if needed).

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document lazy payloads and large-file workflow"
```

---

## Self-Review Notes

- **Spec coverage:** `FileSlice` + read/stream with raw-I/O leak-safe opens (T1); `Parser` `:offset` (T2); `Layout.box_size` FileSlice clause (T3); `Box.read_data/1` (T4); `Serializer.materialize/1` + `serialize/1` routing + `to_iodata` guard (T5); streaming `Serializer.stream/3` (T6); seeking `LazyParser` with re-parse-for-absolute-offsets + threshold + `:eof` length + heuristic-only-on-read (T7); `read/2` `:lazy` + streaming `write/2` + Path.expand/inode overwrite guard (T8); lazy≡eager + headline lazy-faststart + property suites (T9); docs incl. preconditions (T10). Out-of-scope items (nested big leaves, buffered reads, mmap, fragmented/HEIF) intentionally excluded.
- **Type consistency:** `%FileSlice{path, offset, length}` used identically T1→T3→T5→T6→T7→T8; `Layout.box_size/header_size` reused by `stream/3`; `LazyParser.parse_file/2` ↔ `read/2`; `Serializer.materialize/1`/`stream/3` ↔ `serialize/1`/`write/2`.
- **Backward compatibility:** default `read/2` (no `:lazy`) and `serialize/1` on in-memory trees are unchanged; `write/2` still returns `:ok` and emits identical bytes for in-memory trees (verified by T6 + the full-suite runs in T5/T8).
- **Placeholders:** none — every code/test step contains complete content.
```
