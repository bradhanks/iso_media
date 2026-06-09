# Virtual Seekable Media Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add random-access reads over a transform tree: build a `SeekIndex` once, then `read_range/3` (pread-style) and `stream_range/4` (lazy, leak-safe) return any byte range of the tree's would-be `serialize/1` output, reading only the disk bytes the range touches.

**Architecture:** A new `ISOMedia.SeekIndex` flattens the tree (mirroring `Serializer.stream/3`) into an offset-ordered **tuple** of physical segments `%{abs_offset, size, provider}` where `provider :: {:bytes, binary} | {:slice, FileSlice.t()}`. Reads binary-search the tuple (`O(log n)`) and splice forward. `serialize/1` is the property-test oracle. Zero new runtime deps.

**Tech Stack:** Elixir, ExUnit, StreamData (test-only, already a dep). Pure zero-dependency library — no DB/Phoenix/LiveView.

**Spec:** `docs/superpowers/specs/2026-06-09-virtual-seekable-media-design.md` (phase doc: `docs/superpowers/specs/phase-1/2026-06-08-virtual-seekable-media.md`).

**Branch:** `feat/virtual-seekable-media`. Attribution is disabled — do **not** add a `Co-Authored-By` trailer.
> **Test cadence:** tests are written per task but **not run per task** — do not run `mix test`/`mix compile` during the build. The suite runs **once at the end** (Task 9). Commits within a task are made without an intermediate green check.

---

## File Structure

- **Modify** `lib/iso_media/serializer.ex` — promote a public `header_bytes/1` (full pre-payload bytes, incl. uuid) over the existing private `encode_header/2`.
- **Modify** `lib/iso_media/file_slice.ex` — add `read_range/3` (bounded leak-safe partial pread).
- **Create** `lib/iso_media/seek_index.ex` — the `SeekIndex` struct + `build/1`, `read_range/3`, `stream_range/4`, `content_length/1`, and private `clamp_range/3`/`bsearch`/splice/`read_provider`.
- **Modify** `lib/iso_media.ex` — `seek_index/1`, `read_range/3`, `stream_range/4`, `content_length/1` delegations.
- **Modify** `docs/ROADMAP.md`, `CLAUDE.md`, `README.md` — docs (README HTTP/Plug example).
- **Create** `test/iso_media/seek_index_test.exs` — unit + property tests.
- **Modify** `test/iso_media/serializer_test.exs`, `test/iso_media/file_slice_test.exs` — unit tests for the two new helpers.

---

### Task 1: `Serializer.header_bytes/1` (public header encoder)

**Files:**
- Modify: `lib/iso_media/serializer.ex` (add a public function near `encode_header/2`)
- Test: `test/iso_media/serializer_test.exs`

- [ ] **Step 1: Write the test**

Add to `test/iso_media/serializer_test.exs` (inside the test module):

```elixir
  describe "header_bytes/1" do
    alias ISOMedia.{Box, Layout, Serializer}

    test "returns size+type bytes whose length equals header_size for a compact box" do
      box = %Box{type: "free", data: <<1, 2, 3, 4>>, size_mode: :compact}
      bytes = Serializer.header_bytes(box)
      assert bytes == <<12::32, "free">>
      assert byte_size(bytes) == Layout.header_size(box)
    end

    test "appends the 16 uuid bytes after the header for an extended-type box" do
      uuid = :binary.copy(<<0xAB>>, 16)
      box = %Box{type: "uuid", uuid: uuid, data: <<9, 9>>, size_mode: :compact}
      bytes = Serializer.header_bytes(box)
      # size field counts header(8) + uuid(16) + payload(2) = 26; then type; then uuid.
      assert bytes == <<26::32, "uuid", uuid::binary>>
      assert byte_size(bytes) == Layout.header_size(box)
    end

    test "uses the 16-byte largesize header for :large size_mode" do
      box = %Box{type: "mdat", data: <<9, 9, 9, 9>>, size_mode: :large}
      bytes = Serializer.header_bytes(box)
      # large header: size field == 1, then type, then 64-bit largesize (16 header + 4 payload).
      assert bytes == <<1::32, "mdat", 20::64>>
      assert byte_size(bytes) == Layout.header_size(box)
    end
  end
```

- [ ] **Step 2: Implement `header_bytes/1`**

In `lib/iso_media/serializer.ex`, add this public function immediately above the private `encode_header/2` clauses (around line 68, after `encode_payload/1`):

```elixir
  @doc """
  The full pre-payload bytes of a box: the 4/8/16-byte size+type header, followed by
  the 16 `uuid` bytes for an extended-type box. Its length equals `Layout.header_size/1`
  by construction. Exposed so `ISOMedia.SeekIndex` reuses the one header encoder rather
  than duplicating it (the uuid bytes are emitted *after* the header — see `stream_box`).
  """
  def header_bytes(%Box{uuid: uuid} = box) do
    u = uuid || <<>>
    body_len = byte_size(u) + (Layout.box_size(box) - Layout.header_size(box))
    encode_header(box, body_len) <> u
  end
```

- [ ] **Step 3: Commit**

```bash
git add lib/iso_media/serializer.ex test/iso_media/serializer_test.exs
git commit -m "feat: public Serializer.header_bytes/1 (size+type+uuid) for index reuse"
```

---

### Task 2: `FileSlice.read_range/3` (bounded leak-safe partial read)

**Files:**
- Modify: `lib/iso_media/file_slice.ex`
- Test: `test/iso_media/file_slice_test.exs`

- [ ] **Step 1: Write the test**

Add to `test/iso_media/file_slice_test.exs` (it already exercises `FileSlice`; use `@tag :tmp_dir` for the scratch file):

```elixir
  describe "read_range/3" do
    alias ISOMedia.FileSlice

    @tag :tmp_dir
    test "reads a bounded sub-range relative to the slice", %{tmp_dir: tmp} do
      path = Path.join(tmp, "data.bin")
      File.write!(path, <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>)
      # slice covers bytes 2..7 (offset 2, length 6): <<2,3,4,5,6,7>>
      fs = %FileSlice{path: path, offset: 2, length: 6}

      assert FileSlice.read_range(fs, 0, 6) == <<2, 3, 4, 5, 6, 7>>
      assert FileSlice.read_range(fs, 1, 3) == <<3, 4, 5>>
      assert FileSlice.read_range(fs, 6, 0) == <<>>
    end

    @tag :tmp_dir
    test "raises when the sub-range exceeds the slice length", %{tmp_dir: tmp} do
      path = Path.join(tmp, "data.bin")
      File.write!(path, <<0, 1, 2, 3>>)
      fs = %FileSlice{path: path, offset: 0, length: 4}
      assert_raise FunctionClauseError, fn -> FileSlice.read_range(fs, 2, 3) end
    end
  end
```

- [ ] **Step 2: Implement `read_range/3`**

In `lib/iso_media/file_slice.ex`, add after `read/1` (around line 35):

```elixir
  @doc """
  Read `len` bytes starting `rel` bytes into the slice (a bounded sub-range of the
  slice). Opens/preads/closes like `read/1`, so it never holds a file handle. The
  `rel + len <= length` guard makes an out-of-bounds request a contract violation,
  not a silent short read.
  """
  def read_range(%__MODULE__{path: path, offset: offset, length: length}, rel, len)
      when is_integer(rel) and rel >= 0 and is_integer(len) and len >= 0 and rel + len <= length do
    File.open!(path, [:read, :binary, :raw], fn io ->
      case :file.pread(io, offset + rel, len) do
        {:ok, data} when byte_size(data) == len ->
          data

        {:ok, data} ->
          raise "FileSlice.read_range: short read at #{offset + rel} of #{path}: wanted #{len}, got #{byte_size(data)}"

        :eof when len == 0 ->
          <<>>

        :eof ->
          raise "FileSlice.read_range: unexpected EOF reading #{len} bytes at #{offset + rel} of #{path}"

        {:error, reason} ->
          raise "FileSlice.read_range: #{:file.format_error(reason)} reading #{len} bytes at #{offset + rel} of #{path}"
      end
    end)
  end
```

> Note: `:file.pread/3` with `len == 0` can return `:eof`; the `:eof when len == 0` clause returns `<<>>`. The `{:ok, data} when byte_size(data) == len` clause already covers a normal zero read on most platforms.

- [ ] **Step 3: Commit**

```bash
git add lib/iso_media/file_slice.ex test/iso_media/file_slice_test.exs
git commit -m "feat: FileSlice.read_range/3 bounded leak-safe partial read"
```

---

### Task 3: `SeekIndex` struct + `build/1` + `content_length/1`

**Files:**
- Create: `lib/iso_media/seek_index.ex`
- Test: `test/iso_media/seek_index_test.exs`

- [ ] **Step 1: Write the test**

Create `test/iso_media/seek_index_test.exs`:

```elixir
defmodule ISOMedia.SeekIndexTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.{Box, SeekIndex, Serializer}

  describe "build/1 + content_length/1" do
    test "content_length equals byte_size(serialize(tree))" do
      tree = [
        %Box{type: "ftyp", data: <<"isom", 0::32>>, size_mode: :compact},
        %Box{type: "free", data: <<1, 2, 3, 4>>, size_mode: :compact}
      ]

      idx = SeekIndex.build(tree)
      assert SeekIndex.content_length(idx) == byte_size(Serializer.serialize(tree))
    end

    test "skips zero-size (empty) leaf payloads but counts their header" do
      # empty "free" leaf: 8-byte header, 0-byte payload.
      tree = [%Box{type: "free", data: <<>>, size_mode: :compact}]
      idx = SeekIndex.build(tree)
      assert SeekIndex.content_length(idx) == 8
    end

    test "accepts a single %Box{} as well as a list" do
      box = %Box{type: "free", data: <<1, 2>>, size_mode: :compact}
      assert SeekIndex.content_length(SeekIndex.build(box)) == 10
    end
  end
end
```

- [ ] **Step 2: Implement the struct, `build/1`, `content_length/1`**

Create `lib/iso_media/seek_index.ex`:

```elixir
defmodule ISOMedia.SeekIndex do
  @moduledoc """
  A random-access index over a box tree's would-be `serialize/1` output.

  `build/1` flattens the tree (mirroring `ISOMedia.Serializer`) into an offset-ordered
  tuple of physical segments `%{abs_offset, size, provider}`, where
  `provider :: {:bytes, binary} | {:slice, ISOMedia.FileSlice.t()}`. `read_range/3` and
  `stream_range/4` resolve any byte range against the index, reading only the disk bytes
  the range touches. Build once, query many times. The index is opaque.
  """

  alias ISOMedia.{Box, FileSlice, Serializer}

  defstruct [:segments, :count, :byte_size]

  @type t :: %__MODULE__{segments: tuple(), count: non_neg_integer(), byte_size: non_neg_integer()}

  @doc "Build the index from a `%Box{}` or list of boxes (same shapes `serialize/1` accepts)."
  def build(%Box{} = box), do: build([box])

  def build(boxes) when is_list(boxes) do
    {rev, total} = walk(boxes, 0, [])
    segments = rev |> Enum.reverse() |> List.to_tuple()
    %__MODULE__{segments: segments, count: tuple_size(segments), byte_size: total}
  end

  @doc "Total size of the serialized output (the HTTP `Content-Length`); reads no payload bytes."
  def content_length(%__MODULE__{byte_size: bs}), do: bs

  # --- build walk: record physical runs in the exact order serialize/1 emits them ---

  defp walk(boxes, off, acc) do
    Enum.reduce(boxes, {acc, off}, fn box, {a, o} -> walk_box(box, o, a) end)
  end

  defp walk_box(%Box{} = box, off, acc) do
    header = Serializer.header_bytes(box)
    hsize = byte_size(header)
    walk_payload(box, off + hsize, emit(acc, off, hsize, {:bytes, header}))
  end

  # container: header only, then recurse into children
  defp walk_payload(%Box{data: nil, children: children}, off, acc), do: walk(children, off, acc)

  defp walk_payload(%Box{data: %FileSlice{length: len} = fs}, off, acc),
    do: {emit(acc, off, len, {:slice, fs}), off + len}

  defp walk_payload(%Box{data: parts}, off, acc) when is_list(parts),
    do: walk_segments(parts, off, acc)

  defp walk_payload(%Box{data: data}, off, acc) when is_binary(data),
    do: {emit(acc, off, byte_size(data), {:bytes, data}), off + byte_size(data)}

  defp walk_segments(parts, off, acc) do
    Enum.reduce(parts, {acc, off}, fn part, {a, o} -> walk_seg(part, o, a) end)
  end

  defp walk_seg(%FileSlice{length: len} = fs, off, acc),
    do: {emit(acc, off, len, {:slice, fs}), off + len}

  defp walk_seg(bin, off, acc) when is_binary(bin),
    do: {emit(acc, off, byte_size(bin), {:bytes, bin}), off + byte_size(bin)}

  defp walk_seg(parts, off, acc) when is_list(parts), do: walk_segments(parts, off, acc)

  # Zero-size runs (empty leaves) are NOT recorded: keeping every segment size > 0 makes
  # abs_offsets strictly increasing and contiguous, so the splice loop always advances.
  defp emit(acc, _off, 0, _provider), do: acc
  defp emit(acc, off, size, provider), do: [%{abs_offset: off, size: size, provider: provider} | acc]
end
```

- [ ] **Step 3: Commit**

```bash
git add lib/iso_media/seek_index.ex test/iso_media/seek_index_test.exs
git commit -m "feat: SeekIndex.build/1 + content_length/1 (flatten tree to offset-ordered segments)"
```

---

### Task 4: `read_range/3` — oracle first, then clamp/bsearch/splice

**Files:**
- Modify: `lib/iso_media/seek_index.ex`
- Test: `test/iso_media/seek_index_test.exs`

- [ ] **Step 1: Write the property oracle + guard tests**

Add to `test/iso_media/seek_index_test.exs` (the module already has `use ExUnitProperties`):

```elixir
  # --- generators: in-memory trees of leaf + container boxes (the {:bytes,_} path) ---
  defp leaf_type do
    gen all(<<a, b, c, d>> <- binary(length: 4), type = printable(<<a, b, c, d>>),
            not ISOMedia.Registry.container?(type)) do
      type
    end
  end

  defp printable(<<a, b, c, d>>), do: <<az(a), az(b), az(c), az(d)>>
  defp az(byte), do: 0x41 + rem(byte, 26)

  defp leaf_box do
    gen all(type <- leaf_type(), data <- binary(max_length: 40)) do
      %Box{type: type, data: data, size_mode: :compact}
    end
  end

  defp container_box do
    gen all(type <- leaf_type(), kids <- list_of(leaf_box(), max_length: 3)) do
      %Box{type: type, data: nil, children: kids, size_mode: :compact}
    end
  end

  defp tree_gen, do: list_of(one_of([leaf_box(), container_box()]), min_length: 1, max_length: 6)

  # The defining invariant (spec §5): read_range == binary_part(serialize, clamped window).
  defp assert_oracle(boxes, offset, length) do
    idx = SeekIndex.build(boxes)
    full = Serializer.serialize(boxes)
    bs = byte_size(full)
    start = min(offset, bs)
    finish = min(offset + length, bs)
    assert SeekIndex.read_range(idx, offset, length) == :binary.part(full, start, finish - start)
  end

  describe "read_range/3 oracle" do
    property "read_range matches binary_part of serialize for any range (generated trees)" do
      check all(boxes <- tree_gen(), offset <- integer(0..400), length <- integer(0..400)) do
        assert_oracle(boxes, offset, length)
      end
    end

    test "full-range read reproduces serialize/1 exactly" do
      boxes = [
        %Box{type: "ftyp", data: <<"isom", 0::32>>, size_mode: :compact},
        %Box{type: "free", data: <<1, 2, 3, 4, 5, 6>>, size_mode: :compact}
      ]

      idx = SeekIndex.build(boxes)
      assert SeekIndex.read_range(idx, 0, SeekIndex.content_length(idx)) == Serializer.serialize(boxes)
    end

    test "zero-length, past-EOF, and over-long ranges follow HTTP-Range semantics" do
      boxes = [%Box{type: "free", data: <<1, 2, 3, 4>>, size_mode: :compact}]
      idx = SeekIndex.build(boxes)
      bs = SeekIndex.content_length(idx)

      assert SeekIndex.read_range(idx, 0, 0) == <<>>
      assert SeekIndex.read_range(idx, bs, 10) == <<>>
      assert SeekIndex.read_range(idx, bs + 100, 10) == <<>>
      # over-long: returns the available tail, no error
      assert SeekIndex.read_range(idx, 0, bs + 100) == Serializer.serialize(boxes)
    end

    test "raises ArgumentError on negative / non-integer offset or length" do
      idx = SeekIndex.build([%Box{type: "free", data: <<1>>, size_mode: :compact}])
      assert_raise ArgumentError, fn -> SeekIndex.read_range(idx, -1, 4) end
      assert_raise ArgumentError, fn -> SeekIndex.read_range(idx, 0, -4) end
      assert_raise ArgumentError, fn -> SeekIndex.read_range(idx, 1.5, 4) end
    end
  end
```

- [ ] **Step 2: Implement `read_range/3` + helpers**

In `lib/iso_media/seek_index.ex`, add after `content_length/1`:

```elixir
  @doc """
  Return bytes `[offset, offset+length)` of the serialized output. Clamps to the output
  bounds (a read past EOF returns the available tail, not an error — HTTP-Range friendly).
  Raises `ArgumentError` on a negative or non-integer `offset`/`length` (the public boundary
  is fed untrusted HTTP `Range` values; bad input must fail fast, never reach the splice math).
  """
  def read_range(%__MODULE__{} = idx, offset, length)
      when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 0 do
    {start, finish} = clamp_range(offset, length, idx.byte_size)

    if finish == start do
      <<>>
    else
      i = bsearch(idx.segments, idx.count, start)
      idx.segments |> splice(i, start, finish, []) |> IO.iodata_to_binary()
    end
  end

  def read_range(%__MODULE__{}, offset, length) do
    raise ArgumentError,
          "read_range/3 offset and length must be non-negative integers, got: #{inspect({offset, length})}"
  end

  # Canonical clamp — the ONE definition the §5 test oracle is also derived from.
  defp clamp_range(offset, length, bs), do: {min(offset, bs), min(offset + length, bs)}

  # Largest index i with segments[i].abs_offset <= target. Only called when start < byte_size,
  # so count >= 1 and segments[0].abs_offset == 0 <= target, giving a valid i in [0, count-1].
  defp bsearch(segments, count, target), do: bsearch(segments, target, 0, count - 1)

  defp bsearch(_segments, _target, lo, hi) when lo >= hi, do: lo

  defp bsearch(segments, target, lo, hi) do
    mid = div(lo + hi + 1, 2)

    if elem(segments, mid).abs_offset <= target,
      do: bsearch(segments, target, mid, hi),
      else: bsearch(segments, target, lo, mid - 1)
  end

  # Walk forward from segment i, slicing each segment's overlap with [pos, finish).
  defp splice(_segments, _i, pos, finish, acc) when pos >= finish, do: Enum.reverse(acc)

  defp splice(segments, i, pos, finish, acc) do
    seg = elem(segments, i)
    seg_hi = seg.abs_offset + seg.size
    take_hi = min(finish, seg_hi)
    rel = pos - seg.abs_offset
    chunk = read_provider(seg.provider, rel, take_hi - pos)
    splice(segments, i + 1, take_hi, finish, [chunk | acc])
  end

  defp read_provider({:bytes, bin}, rel, n), do: :binary.part(bin, rel, n)
  defp read_provider({:slice, fs}, rel, n), do: FileSlice.read_range(fs, rel, n)
```

- [ ] **Step 3: Commit**

```bash
git add lib/iso_media/seek_index.ex test/iso_media/seek_index_test.exs
git commit -m "feat: SeekIndex.read_range/3 with clamp/bsearch/splice + input guards, proved by serialize oracle"
```

---

### Task 5: `stream_range/4` — lazy, leak-safe streaming

**Files:**
- Modify: `lib/iso_media/seek_index.ex`
- Test: `test/iso_media/seek_index_test.exs`

- [ ] **Step 1: Write the tests**

Add to `test/iso_media/seek_index_test.exs`:

```elixir
  describe "stream_range/4" do
    test "streamed bytes equal read_range for the same window, in chunk_size pieces" do
      boxes = [
        %Box{type: "ftyp", data: <<"isom", 0::32>>, size_mode: :compact},
        %Box{type: "free", data: :binary.copy(<<7>>, 50), size_mode: :compact}
      ]

      idx = SeekIndex.build(boxes)
      bs = SeekIndex.content_length(idx)

      chunks = idx |> SeekIndex.stream_range(0, bs, 8) |> Enum.to_list()
      assert IO.iodata_to_binary(chunks) == SeekIndex.read_range(idx, 0, bs)
      # all chunks 8 bytes except possibly the last
      assert Enum.all?(Enum.drop(chunks, -1), &(byte_size(&1) == 8))
      assert length(chunks) == ceil(bs / 8)
    end

    @tag :tmp_dir
    test "streams a FileSlice-backed range lazily and correctly", %{tmp_dir: tmp} do
      # Build a file with a >64-byte mdat so lazy parse keeps it as a FileSlice.
      payload = :binary.copy(<<0xAB>>, 300)
      ftyp = <<12::32, "ftyp", "isom">>
      mdat = <<8 + byte_size(payload)::32, "mdat", payload::binary>>
      path = Path.join(tmp, "big.mp4")
      File.write!(path, ftyp <> mdat)

      {:ok, boxes} = ISOMedia.read(path, lazy: true, lazy_threshold: 64)
      assert Enum.any?(boxes, &match?(%Box{data: %ISOMedia.FileSlice{}}, &1))

      idx = SeekIndex.build(boxes)
      full = Serializer.serialize(boxes)

      # a mid-file sub-range that lands inside the FileSlice
      streamed = idx |> SeekIndex.stream_range(40, 120, 16) |> Enum.into(<<>>, & &1)
      assert streamed == :binary.part(full, 40, 120)
    end

    test "raises ArgumentError on negative / non-integer offset or length" do
      idx = SeekIndex.build([%Box{type: "free", data: <<1>>, size_mode: :compact}])
      assert_raise ArgumentError, fn -> SeekIndex.stream_range(idx, -1, 4) |> Enum.to_list() end
      assert_raise ArgumentError, fn -> SeekIndex.stream_range(idx, 0, -1) |> Enum.to_list() end
    end
  end
```

- [ ] **Step 2: Implement `stream_range/4`**

In `lib/iso_media/seek_index.ex`, add after `read_provider/3`:

```elixir
  @doc """
  Lazily stream bytes `[offset, offset+length)` as a `Stream` of `chunk_size`-byte binaries.
  Memory-safe for large `FileSlice`-backed ranges; the underlying file is opened once per
  touched slice (not per chunk) and closed deterministically on halt, error, or completion
  via `Stream.resource/3`'s `after_fun`. Same input guards as `read_range/3`.
  """
  def stream_range(idx, offset, length, chunk_size \\ 65_536)

  def stream_range(%__MODULE__{} = idx, offset, length, chunk_size)
      when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 0 and
             is_integer(chunk_size) and chunk_size > 0 do
    {start, finish} = clamp_range(offset, length, idx.byte_size)

    Stream.resource(
      fn -> %{pos: start, fd: nil} end,
      fn state -> stream_next(state, idx, finish, chunk_size) end,
      fn state -> close_fd(state) end
    )
  end

  def stream_range(%__MODULE__{}, offset, length, _chunk_size) do
    raise ArgumentError,
          "stream_range/4 offset and length must be non-negative integers, got: #{inspect({offset, length})}"
  end

  defp stream_next(%{pos: pos} = state, _idx, finish, _chunk) when pos >= finish do
    {:halt, state}
  end

  defp stream_next(%{pos: pos} = state, idx, finish, chunk_size) do
    seg = elem(idx.segments, bsearch(idx.segments, idx.count, pos))
    seg_hi = seg.abs_offset + seg.size
    take_hi = Enum.min([finish, seg_hi, pos + chunk_size])
    rel = pos - seg.abs_offset
    n = take_hi - pos

    case seg.provider do
      {:bytes, bin} ->
        {[:binary.part(bin, rel, n)], %{close_fd(state) | pos: take_hi}}

      {:slice, fs} ->
        {io, state} = ensure_open(state, fs)
        {[pread!(io, fs.offset + rel, n)], %{state | pos: take_hi}}
    end
  end

  # Keep the same fd open across consecutive chunks of one FileSlice; reopen on slice change.
  defp ensure_open(%{fd: {fs, io}} = state, fs), do: {io, state}

  defp ensure_open(state, fs) do
    state = close_fd(state)
    io = File.open!(fs.path, [:read, :binary, :raw])
    {io, %{state | fd: {fs, io}}}
  end

  defp close_fd(%{fd: nil} = state), do: state

  defp close_fd(%{fd: {_fs, io}} = state) do
    File.close(io)
    %{state | fd: nil}
  end

  defp pread!(io, at, n) do
    case :file.pread(io, at, n) do
      {:ok, data} when byte_size(data) == n -> data
      :eof when n == 0 -> <<>>
      :eof -> raise "SeekIndex.stream_range: unexpected EOF reading #{n} bytes at #{at}"
      {:ok, data} -> raise "SeekIndex.stream_range: short read at #{at}: wanted #{n}, got #{byte_size(data)}"
      {:error, reason} -> raise "SeekIndex.stream_range: #{:file.format_error(reason)} at #{at}"
    end
  end
```

- [ ] **Step 3: Commit**

```bash
git add lib/iso_media/seek_index.ex test/iso_media/seek_index_test.exs
git commit -m "feat: SeekIndex.stream_range/4 lazy leak-safe streaming via Stream.resource/3"
```

---

### Task 6: `ISOMedia` delegations

**Files:**
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media/seek_index_test.exs`

- [ ] **Step 1: Write the test**

Add to `test/iso_media/seek_index_test.exs`:

```elixir
  describe "ISOMedia delegations" do
    test "seek_index/read_range/stream_range/content_length are reachable from ISOMedia" do
      boxes = [%Box{type: "free", data: <<1, 2, 3, 4, 5, 6, 7, 8>>, size_mode: :compact}]
      idx = ISOMedia.seek_index(boxes)

      assert ISOMedia.content_length(idx) == byte_size(Serializer.serialize(boxes))
      assert ISOMedia.read_range(idx, 0, 4) == :binary.part(Serializer.serialize(boxes), 0, 4)

      streamed = idx |> ISOMedia.stream_range(0, ISOMedia.content_length(idx), 4) |> Enum.into(<<>>, & &1)
      assert streamed == Serializer.serialize(boxes)
    end
  end
```

- [ ] **Step 2: Add the delegations**

In `lib/iso_media.ex`, add after the `faststart/1` function (around line 121):

```elixir
  @doc "Build a `ISOMedia.SeekIndex` for random-access reads over a tree. See `ISOMedia.SeekIndex.build/1`."
  @spec seek_index(tree() | ISOMedia.Box.t()) :: ISOMedia.SeekIndex.t()
  def seek_index(boxes), do: ISOMedia.SeekIndex.build(boxes)

  @doc "Read bytes `[offset, offset+length)` of a tree's serialization. See `ISOMedia.SeekIndex.read_range/3`."
  @spec read_range(ISOMedia.SeekIndex.t(), non_neg_integer(), non_neg_integer()) :: binary()
  def read_range(index, offset, length), do: ISOMedia.SeekIndex.read_range(index, offset, length)

  @doc "Lazily stream bytes `[offset, offset+length)` of a tree's serialization. See `ISOMedia.SeekIndex.stream_range/4`."
  @spec stream_range(ISOMedia.SeekIndex.t(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          Enumerable.t()
  def stream_range(index, offset, length, chunk_size \\ 65_536),
    do: ISOMedia.SeekIndex.stream_range(index, offset, length, chunk_size)

  @doc "Total serialized size of the indexed tree (HTTP `Content-Length`). See `ISOMedia.SeekIndex.content_length/1`."
  @spec content_length(ISOMedia.SeekIndex.t()) :: non_neg_integer()
  def content_length(index), do: ISOMedia.SeekIndex.content_length(index)
```

- [ ] **Step 3: Commit**

```bash
git add lib/iso_media.ex test/iso_media/seek_index_test.exs
git commit -m "feat: ISOMedia.{seek_index,read_range,stream_range,content_length} delegations"
```

---

### Task 7: Provider coverage — uuid, lazy FileSlice, segment-list composition, edges

**Files:**
- Test: `test/iso_media/seek_index_test.exs`

These prove `read_range` over every provider kind and the spec §6/§7 cases. They pass on top of Tasks 4–5 (no new lib code) — characterization tests locking in correctness.

- [ ] **Step 1: Add the coverage tests**

Add to `test/iso_media/seek_index_test.exs`:

```elixir
  describe "read_range over every provider kind" do
    test "uuid extended-type box (header+uuid provider) round-trips exactly" do
      uuid = :binary.copy(<<0xCD>>, 16)
      boxes = [
        %Box{type: "ftyp", data: <<"isom", 0::32>>, size_mode: :compact},
        %Box{type: "uuid", uuid: uuid, data: <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>, size_mode: :compact}
      ]

      idx = SeekIndex.build(boxes)
      full = Serializer.serialize(boxes)

      # exhaustively check every (offset, length) sub-window
      for offset <- 0..byte_size(full), length <- 0..(byte_size(full) - offset) do
        assert SeekIndex.read_range(idx, offset, length) == :binary.part(full, offset, length)
      end
    end

    test "largesize (:large) header box round-trips through read_range (spec §6)" do
      boxes = [%Box{type: "mdat", data: <<1, 2, 3, 4, 5, 6, 7, 8>>, size_mode: :large}]
      idx = SeekIndex.build(boxes)
      full = Serializer.serialize(boxes)

      for offset <- 0..byte_size(full), length <- 0..(byte_size(full) - offset) do
        assert SeekIndex.read_range(idx, offset, length) == :binary.part(full, offset, length)
      end
    end

    @tag :tmp_dir
    test "random ranges over a lazy FileSlice-backed tree match the oracle", %{tmp_dir: tmp} do
      payload = :binary.copy(<<0x5A>>, 400)
      bin = <<12::32, "ftyp", "isom", 8 + byte_size(payload)::32, "mdat", payload::binary>>
      path = Path.join(tmp, "lazy.mp4")
      File.write!(path, bin)

      {:ok, boxes} = ISOMedia.read(path, lazy: true, lazy_threshold: 64)
      full = Serializer.serialize(boxes)
      idx = SeekIndex.build(boxes)

      check all(offset <- integer(0..500), length <- integer(0..500)) do
        start = min(offset, byte_size(full))
        finish = min(offset + length, byte_size(full))
        assert SeekIndex.read_range(idx, offset, length) == :binary.part(full, start, finish - start)
      end
    end

    test "composition: read_range over an in-memory trim tree (segment-list mdat) matches the oracle" do
      original = File.read!(Path.join([__DIR__, "..", "fixtures", "sample.mp4"]))
      {:ok, boxes} = ISOMedia.parse(original)
      # trim synthesizes a segment-list mdat entirely in memory — this directly exercises
      # build/1's walk_payload(list)/walk_seg recursion (a `{:bytes,_}`/nested-list provider),
      # not just header/payload splicing. (trim is shipped on main; no other branch needed.)
      synth = ISOMedia.trim(boxes, 0, 1)
      assert Enum.any?(synth, fn b -> b.type == "mdat" and is_list(b.data) end)

      full = Serializer.serialize(synth)
      idx = SeekIndex.build(synth)

      check all(offset <- integer(0..(byte_size(full) + 50)), length <- integer(0..300)) do
        start = min(offset, byte_size(full))
        finish = min(offset + length, byte_size(full))
        assert SeekIndex.read_range(idx, offset, length) == :binary.part(full, start, finish - start)
      end
    end
  end
```

> Note: the assertion `Enum.any?(... is_list(b.data) ...)` first confirms `trim` actually produced a segment-list `mdat`, so the oracle below genuinely exercises the segment-list provider path rather than passing vacuously.

- [ ] **Step 2: Commit**

```bash
git add test/iso_media/seek_index_test.exs
git commit -m "test: SeekIndex coverage for uuid, lazy FileSlice, and in-memory composition"
```

---

### Task 8: Documentation

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docs/ROADMAP.md`

- [ ] **Step 1: Add the README HTTP/Plug example (documentation only — no compiled code)**

Append a section to `README.md`:

```markdown
## Serving byte ranges (streaming origin)

`ISOMedia.seek_index/1` builds a random-access index over a (possibly transformed,
possibly lazy) tree; `read_range/3` and `stream_range/4` then return any byte range of
its `serialize/1` output, reading only the bytes the range touches. Wire it into any web
server (no dependency is bundled). Validate the `Range` header in the handler — the
library guards too, as a backstop — and use `stream_range/4` for large ranges so a
hostile request streams in bounded memory:

    # Plug sketch — parse "Range: bytes=START-END", clamp, stream a 206.
    def serve(conn, idx) do
      total = ISOMedia.content_length(idx)

      case parse_range(get_req_header(conn, "range"), total) do
        {start, finish} ->                       # satisfiable [start, finish)
          conn
          |> put_resp_header("content-range", "bytes #{start}-#{finish - 1}/#{total}")
          |> put_resp_header("accept-ranges", "bytes")
          |> send_chunked(206)
          |> stream_into(ISOMedia.stream_range(idx, start, finish - start))

        :unsatisfiable ->
          send_resp(conn, 416, "")

        :none ->                                 # no Range: send the whole thing
          conn
          |> put_resp_header("content-length", Integer.to_string(total))
          |> send_chunked(200)
          |> stream_into(ISOMedia.stream_range(idx, 0, total))
      end
    end

`parse_range/2` and `stream_into/2` are yours to implement against your server; the index
is immutable, so build it once and share it across requests (e.g. cache it in
`:persistent_term`). The `O(range)` memory guarantee assumes a `FileSlice`-backed lazy tree.
```

- [ ] **Step 2: Update `CLAUDE.md`**

In `CLAUDE.md`, add a module-map entry for `SeekIndex` (next to `MdatSource`/`Layout`):

```markdown
- `ISOMedia.SeekIndex` (`lib/iso_media/seek_index.ex`) — random-access index over a tree's
  would-be `serialize/1` output. `build/1` flattens the tree into an offset-ordered tuple of
  physical segments (`{:bytes, binary}` | `{:slice, FileSlice}`); `read_range/3` binary-searches
  + splices (pread-style), `stream_range/4` streams lazily/leak-safely (`Stream.resource/3`),
  `content_length/1` is the total size. Proved byte-exact against `serialize/1`. Reuses the now
  public `Serializer.header_bytes/1`. Exposed as `ISOMedia.{seek_index,read_range,stream_range,content_length}`.
```

- [ ] **Step 3: Update `docs/ROADMAP.md`**

In `docs/ROADMAP.md`, under "## Shipped", add to the most recent version line (or a new "Unreleased" bullet):

```markdown
- **Virtual seekable media** — `seek_index/1` + `read_range/3` (pread-style) + `stream_range/4`
  (lazy, leak-safe) return any byte range of a tree's serialization without materializing it; a
  streaming-origin primitive. Byte-exact against `serialize/1`.
```

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md docs/ROADMAP.md
git commit -m "docs: virtual seekable media (README HTTP example, CLAUDE.md, ROADMAP)"
```

---

### Task 9: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Format check**

Run: `mix format --check-formatted`
Expected: no output, exit 0. (If it fails, `mix format` and amend the relevant commit.)

- [ ] **Step 2: Full test suite**

Run: `mix test`
Expected: PASS — all tests and properties green, 0 failures. The new module adds tests; no existing behavior changes (`serialize/1`, `Layout`, `FileSlice.read/1` are untouched; `header_bytes/1` is additive over the unchanged private `encode_header/2`).

- [ ] **Step 3: Warnings-as-errors compile**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean (no unused-variable/private-function warnings — `encode_header/2` is still used by `encode_box`, `stream_box`, and now `header_bytes/1`).

- [ ] **Step 4: Byte-exact invariant spot check (optional, in IEx)**

Run: `mix run -e 'alias ISOMedia, as: M; {:ok, b} = M.read("test/fixtures/sample.mp4"); idx = M.seek_index(b); ^idx = idx; full = M.serialize(b); true = M.read_range(idx, 0, M.content_length(idx)) == full; IO.puts("byte-exact OK")'`
Expected: prints `byte-exact OK`.
