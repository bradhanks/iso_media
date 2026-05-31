# ISO Media Box Surgery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pure-Elixir library that parses any ISOBMFF (MP4/MOV/M4A/HEIF) file into a generic, lossless tree of boxes, lets you navigate/edit/reorder them immutably, and re-serializes byte-for-byte.

**Architecture:** A single generic `%ISOMedia.Box{}` struct represents every box (container = `data: nil` + `children`; leaf = `data: binary`). A `Parser` decodes binary → boxes via pattern matching; a `Serializer` rebuilds bytes via iolists honoring the recorded `size_mode`. A `Registry` classifies containers (with an opt-in heuristic). `ISOMedia.Box` provides path-based navigation/editing. Typed views in `ISOMedia.Boxes.*` layer struct access onto known boxes without the core depending on them.

**Tech Stack:** Elixir 1.19 / OTP 29, ExUnit, StreamData (test-only, property tests), ffmpeg (test fixture generation).

**Conventions for every commit in this plan:** end the commit message with the trailer:
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

---

### Task 1: Project setup & cleanup

**Files:**
- Modify: `mix.exs`
- Delete: `lib/iso_media/movie_box.ex`, `lib/iso_media/file_type_box.ex`, `lib/core/iso_ftyp.ex`, `lib/iso_media.ex`
- Modify: `test/iso_media_test.exs`

- [ ] **Step 1: Initialize git (workflow needs commits)**

Run:
```bash
git init && git add -A && git commit -m "chore: snapshot existing skeleton before rework"
```
Expected: a repo is created and the current files are committed.

- [ ] **Step 2: Replace `mix.exs` deps and app**

Replace the `deps/0` and `application/0` functions in `mix.exs` with:

```elixir
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
```

- [ ] **Step 3: Delete obsolete skeleton files**

Run:
```bash
git rm lib/iso_media/movie_box.ex lib/iso_media/file_type_box.ex lib/core/iso_ftyp.ex lib/iso_media.ex
rmdir lib/core 2>/dev/null || true
```
Expected: files removed (the empty `lib/core` directory is cleaned up).

- [ ] **Step 4: Replace the placeholder test**

Overwrite `test/iso_media_test.exs` with:

```elixir
defmodule ISOMediaTest do
  use ExUnit.Case
  doctest ISOMedia
end
```

(`ISOMedia` is created in Task 10; until then this file has no tests, which is valid.)

- [ ] **Step 5: Fetch deps and verify compile**

Run: `mix deps.get && mix compile`
Expected: compiles with no errors (the deleted modules are gone; nothing references them yet).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: reset project to box-surgery foundation"
```

---

### Task 2: The generic Box struct

**Files:**
- Create: `lib/iso_media/box.ex`
- Test: `test/iso_media/box_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/box_test.exs`:

```elixir
defmodule ISOMedia.BoxTest do
  use ExUnit.Case
  alias ISOMedia.Box

  test "defaults: a fresh box is a compact container with no children" do
    box = %Box{type: "moov"}
    assert box.type == "moov"
    assert box.data == nil
    assert box.children == []
    assert box.uuid == nil
    assert box.size_mode == :compact
  end

  test "container?/1 and leaf?/1 distinguish by data" do
    container = %Box{type: "moov", data: nil, children: []}
    leaf = %Box{type: "free", data: <<0, 0>>}
    assert Box.container?(container)
    refute Box.leaf?(container)
    assert Box.leaf?(leaf)
    refute Box.container?(leaf)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/box_test.exs`
Expected: FAIL — `ISOMedia.Box.__struct__/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/iso_media/box.ex`:

```elixir
defmodule ISOMedia.Box do
  @moduledoc """
  A single generic ISOBMFF box.

  * `container = data: nil` with `children`
  * `leaf      = data: binary` with no children
  * `size_mode` records how the original size field was encoded so
    serialization can reproduce exact bytes.
  """

  defstruct type: nil, data: nil, children: [], uuid: nil, size_mode: :compact

  @type t :: %__MODULE__{
          type: String.t(),
          data: binary() | nil,
          children: [t()],
          uuid: <<_::128>> | nil,
          size_mode: :compact | :large | :eof
        }

  @doc "True when the box holds child boxes rather than a raw payload."
  def container?(%__MODULE__{data: nil}), do: true
  def container?(%__MODULE__{}), do: false

  @doc "True when the box holds a raw payload rather than children."
  def leaf?(%__MODULE__{data: nil}), do: false
  def leaf?(%__MODULE__{}), do: true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/box_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/box.ex test/iso_media/box_test.exs
git commit -m "feat: add generic Box struct with container/leaf predicates"
```

---

### Task 3: Registry of container types

**Files:**
- Create: `lib/iso_media/registry.ex`
- Test: `test/iso_media/registry_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/registry_test.exs`:

```elixir
defmodule ISOMedia.RegistryTest do
  use ExUnit.Case
  alias ISOMedia.Registry

  test "known container types are recognized" do
    assert Registry.container?("moov")
    assert Registry.container?("trak")
    assert Registry.container?("stbl")
  end

  test "leaf / unknown types are not containers" do
    refute Registry.container?("mvhd")
    refute Registry.container?("free")
    refute Registry.container?("XXXX")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/registry_test.exs`
Expected: FAIL — `ISOMedia.Registry.container?/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/iso_media/registry.ex`:

```elixir
defmodule ISOMedia.Registry do
  @moduledoc "Classifies which box types are containers (hold child boxes)."

  @containers ~w(
    moov trak mdia minf stbl dinf edts udta mvex moof traf
    mfra meco strk sinf schi
  )

  @doc "True when `type` is a known container box type."
  def container?(type) when is_binary(type), do: type in @containers
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/registry_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/registry.ex test/iso_media/registry_test.exs
git commit -m "feat: add container-type registry"
```

---

### Task 4: Parser — leaf and sibling boxes (compact size)

**Files:**
- Create: `lib/iso_media/parser.ex`
- Test: `test/iso_media/parser_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/parser_test.exs`:

```elixir
defmodule ISOMedia.ParserTest do
  use ExUnit.Case
  alias ISOMedia.{Box, Parser}

  test "parses a single compact leaf box" do
    # size=12 (8 header + 4 payload), type "free", payload <<1,2,3,4>>
    bin = <<12::32, "free", 1, 2, 3, 4>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert %Box{type: "free", data: <<1, 2, 3, 4>>, children: [], size_mode: :compact} = box
  end

  test "parses a sequence of sibling boxes" do
    bin = <<8::32, "free", 9::32, "skip", 0>>
    assert {:ok, [a, b]} = Parser.parse(bin)
    assert %Box{type: "free", data: ""} = a
    assert %Box{type: "skip", data: <<0>>} = b
  end

  test "empty input parses to an empty list" do
    assert {:ok, []} = Parser.parse(<<>>)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/parser_test.exs`
Expected: FAIL — `ISOMedia.Parser.parse/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/iso_media/parser.ex`:

```elixir
defmodule ISOMedia.Parser do
  @moduledoc "Decodes an ISOBMFF binary into a list of `ISOMedia.Box` structs."

  alias ISOMedia.{Box, Registry}

  @doc """
  Parse `binary` into `{:ok, [%Box{}]}`, or `{:error, reason}` on malformed input.

  Options:
    * `:heuristic` (default `false`) — sniff unknown box types for nested boxes.
  """
  def parse(binary, opts \\ []) when is_binary(binary) do
    {:ok, parse_boxes(binary, opts)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_boxes(<<>>, _opts), do: []

  defp parse_boxes(binary, opts) do
    {box, rest} = parse_box(binary, opts)
    [box | parse_boxes(rest, opts)]
  end

  defp parse_box(<<size::32, type::binary-size(4), after_type::binary>>, opts) do
    {size_mode, payload, remainder} = take_payload(size, after_type)
    {uuid, payload} = take_uuid(type, payload)

    box =
      if container?(type, payload, opts) do
        %Box{type: type, data: nil, children: parse_boxes(payload, opts), uuid: uuid, size_mode: size_mode}
      else
        %Box{type: type, data: payload, children: [], uuid: uuid, size_mode: size_mode}
      end

    {box, remainder}
  end

  # size == 1 → 64-bit largesize follows (header is 16 bytes total)
  defp take_payload(1, <<largesize::64, rest::binary>>) do
    payload_len = largesize - 16
    <<payload::binary-size(payload_len), remainder::binary>> = rest
    {:large, payload, remainder}
  end

  # size == 0 → box runs to end of input
  defp take_payload(0, rest), do: {:eof, rest, <<>>}

  # normal 32-bit size (header is 8 bytes)
  defp take_payload(size, rest) do
    payload_len = size - 8
    <<payload::binary-size(payload_len), remainder::binary>> = rest
    {:compact, payload, remainder}
  end

  defp take_uuid("uuid", <<uuid::binary-size(16), payload::binary>>), do: {uuid, payload}
  defp take_uuid(_type, payload), do: {nil, payload}

  defp container?(type, _payload, _opts), do: Registry.container?(type)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/parser_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/parser.ex test/iso_media/parser_test.exs
git commit -m "feat: parse compact leaf and sibling boxes"
```

---

### Task 5: Parser — container recursion

**Files:**
- Modify: `test/iso_media/parser_test.exs`

(Recursion is already implemented in Task 4; this task proves it with a container fixture.)

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/parser_test.exs` (inside the module):

```elixir
  test "recurses into a known container box" do
    # moov(size 24) { mvhd(size 8, empty) ; free(size 8, empty) }
    inner = <<8::32, "mvhd", 8::32, "free">>
    bin = <<8 + byte_size(inner)::32, "moov", inner::binary>>

    assert {:ok, [moov]} = Parser.parse(bin)
    assert moov.type == "moov"
    assert moov.data == nil
    assert [%{type: "mvhd"}, %{type: "free"}] = moov.children
  end
```

- [ ] **Step 2: Run test to verify it fails (then passes)**

Run: `mix test test/iso_media/parser_test.exs`
Expected: PASS — recursion already works. (If it fails, the bug is in Task 4; fix there.)

- [ ] **Step 3: Commit**

```bash
git add test/iso_media/parser_test.exs
git commit -m "test: cover container recursion in parser"
```

---

### Task 6: Parser — 64-bit largesize and size-0-to-EOF

**Files:**
- Modify: `test/iso_media/parser_test.exs`

(Behavior implemented in Task 4; this task adds coverage for the size escape hatches.)

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/parser_test.exs`:

```elixir
  test "parses a 64-bit largesize box" do
    # size field == 1, largesize == 20 (16 header + 4 payload)
    bin = <<1::32, "mdat", 20::64, 9, 9, 9, 9>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert %Box{type: "mdat", data: <<9, 9, 9, 9>>, size_mode: :large} = box
  end

  test "parses a size-0 box that runs to end of input" do
    bin = <<0::32, "mdat", 7, 7, 7>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert %Box{type: "mdat", data: <<7, 7, 7>>, size_mode: :eof} = box
  end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/iso_media/parser_test.exs`
Expected: PASS (largesize/eof handled in Task 4).

- [ ] **Step 3: Commit**

```bash
git add test/iso_media/parser_test.exs
git commit -m "test: cover largesize and size-0 boxes"
```

---

### Task 7: Parser — uuid (vendor) boxes

**Files:**
- Modify: `test/iso_media/parser_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/parser_test.exs`:

```elixir
  test "parses a uuid box, splitting out the 16-byte extended type" do
    uuid = <<0::128>>
    # size = 8 header + 16 uuid + 3 payload = 27
    bin = <<27::32, "uuid", uuid::binary, 1, 2, 3>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert box.type == "uuid"
    assert box.uuid == uuid
    assert box.data == <<1, 2, 3>>
  end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/iso_media/parser_test.exs`
Expected: PASS (uuid handled in Task 4).

- [ ] **Step 3: Commit**

```bash
git add test/iso_media/parser_test.exs
git commit -m "test: cover uuid extended-type boxes"
```

---

### Task 8: Serializer — byte-perfect round-trip

**Files:**
- Create: `lib/iso_media/serializer.ex`
- Test: `test/iso_media/serializer_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/serializer_test.exs`:

```elixir
defmodule ISOMedia.SerializerTest do
  use ExUnit.Case
  alias ISOMedia.{Parser, Serializer}

  defp round_trips!(bin) do
    {:ok, boxes} = Parser.parse(bin)
    assert Serializer.serialize(boxes) == bin
  end

  test "round-trips a compact leaf" do
    round_trips!(<<12::32, "free", 1, 2, 3, 4>>)
  end

  test "round-trips siblings" do
    round_trips!(<<8::32, "free", 9::32, "skip", 0>>)
  end

  test "round-trips a nested container" do
    inner = <<8::32, "mvhd", 8::32, "free">>
    round_trips!(<<8 + byte_size(inner)::32, "moov", inner::binary>>)
  end

  test "round-trips a 64-bit largesize box" do
    round_trips!(<<1::32, "mdat", 20::64, 9, 9, 9, 9>>)
  end

  test "round-trips a size-0 box" do
    round_trips!(<<0::32, "mdat", 7, 7, 7>>)
  end

  test "round-trips a uuid box" do
    round_trips!(<<27::32, "uuid", 0::128, 1, 2, 3>>)
  end

  test "serialize/1 accepts a single box" do
    {:ok, [box]} = Parser.parse(<<8::32, "free">>)
    assert Serializer.serialize(box) == <<8::32, "free">>
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: FAIL — `ISOMedia.Serializer.serialize/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/iso_media/serializer.ex`:

```elixir
defmodule ISOMedia.Serializer do
  @moduledoc "Serializes `ISOMedia.Box` trees back into ISOBMFF binary."

  alias ISOMedia.Box

  @doc "Serialize a box or list of boxes to a binary."
  def serialize(%Box{} = box), do: serialize([box])

  def serialize(boxes) when is_list(boxes) do
    boxes |> Enum.map(&encode_box/1) |> IO.iodata_to_binary()
  end

  defp encode_box(%Box{} = box) do
    body = [box.uuid || <<>>, encode_payload(box)]
    body_len = IO.iodata_length(body)
    [encode_header(box, body_len), body]
  end

  defp encode_payload(%Box{data: nil, children: children}), do: Enum.map(children, &encode_box/1)
  defp encode_payload(%Box{data: data}), do: data

  # compact: total size = 8 (header) + body
  defp encode_header(%Box{type: type, size_mode: :compact}, body_len) do
    <<8 + body_len::32, type::binary>>
  end

  # large: size field == 1, largesize = 16 (header) + body
  defp encode_header(%Box{type: type, size_mode: :large}, body_len) do
    <<1::32, type::binary, 16 + body_len::64>>
  end

  # eof: size field == 0
  defp encode_header(%Box{type: type, size_mode: :eof}, _body_len) do
    <<0::32, type::binary>>
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/serializer_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/serializer.ex test/iso_media/serializer_test.exs
git commit -m "feat: serialize box trees with byte-perfect round-trip"
```

---

### Task 9: Registry heuristic + parser opt-in

**Files:**
- Modify: `lib/iso_media/registry.ex`
- Modify: `lib/iso_media/parser.ex:` (the `container?/3` private function)
- Test: `test/iso_media/registry_test.exs`, `test/iso_media/parser_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/iso_media/registry_test.exs`:

```elixir
  test "looks_like_boxes?/1 detects a sequence of valid child boxes" do
    payload = <<8::32, "free", 9::32, "skip", 0>>
    assert ISOMedia.Registry.looks_like_boxes?(payload)
  end

  test "looks_like_boxes?/1 rejects arbitrary leaf bytes" do
    refute ISOMedia.Registry.looks_like_boxes?(<<0, 1, 2, 3, 4, 5, 6, 7, 8>>)
    refute ISOMedia.Registry.looks_like_boxes?(<<1, 2>>)
  end
```

Add to `test/iso_media/parser_test.exs`:

```elixir
  test "unknown box stays a leaf without :heuristic" do
    inner = <<8::32, "free">>
    bin = <<8 + byte_size(inner)::32, "XBOX", inner::binary>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert box.data == inner
    assert box.children == []
  end

  test "unknown box recurses with :heuristic enabled" do
    inner = <<8::32, "free">>
    bin = <<8 + byte_size(inner)::32, "XBOX", inner::binary>>
    assert {:ok, [box]} = Parser.parse(bin, heuristic: true)
    assert box.data == nil
    assert [%{type: "free"}] = box.children
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/iso_media/registry_test.exs test/iso_media/parser_test.exs`
Expected: FAIL — `looks_like_boxes?/1 is undefined` and the heuristic parser test fails (no recursion).

- [ ] **Step 3: Add the heuristic to Registry**

Append these functions inside `lib/iso_media/registry.ex` (before the final `end`):

```elixir
  @doc """
  Best-effort: does `payload` look like a clean sequence of child boxes?
  Only compact (32-bit) sizes are considered. Used by the opt-in heuristic.
  """
  def looks_like_boxes?(payload) when is_binary(payload) and byte_size(payload) >= 8 do
    scan(payload)
  end

  def looks_like_boxes?(_), do: false

  defp scan(<<>>), do: true

  defp scan(<<size::32, type::binary-size(4), rest::binary>>)
       when size >= 8 and byte_size(rest) >= size - 8 do
    if printable_type?(type) do
      payload_len = size - 8
      <<_payload::binary-size(payload_len), remainder::binary>> = rest
      scan(remainder)
    else
      false
    end
  end

  defp scan(_), do: false

  defp printable_type?(type) do
    type |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E))
  end
```

- [ ] **Step 4: Wire the heuristic into the parser**

In `lib/iso_media/parser.ex`, replace the `container?/3` function with:

```elixir
  defp container?(type, payload, opts) do
    Registry.container?(type) or
      (Keyword.get(opts, :heuristic, false) and Registry.looks_like_boxes?(payload))
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/iso_media/registry_test.exs test/iso_media/parser_test.exs`
Expected: PASS (all tests, including the new heuristic ones).

- [ ] **Step 6: Commit**

```bash
git add lib/iso_media/registry.ex lib/iso_media/parser.ex test/iso_media/registry_test.exs test/iso_media/parser_test.exs
git commit -m "feat: opt-in heuristic container detection"
```

---

### Task 10: Public API — `ISOMedia`

**Files:**
- Create: `lib/iso_media.ex`
- Test: `test/iso_media_test.exs`

- [ ] **Step 1: Write the failing test**

Overwrite `test/iso_media_test.exs`:

```elixir
defmodule ISOMediaTest do
  use ExUnit.Case
  doctest ISOMedia

  @bin <<12::32, "free", 1, 2, 3, 4>>

  test "parse/1 and serialize/1 round-trip" do
    assert {:ok, boxes} = ISOMedia.parse(@bin)
    assert ISOMedia.serialize(boxes) == @bin
  end

  test "read/1 and write/2 round-trip via a temp file" do
    path = Path.join(System.tmp_dir!(), "iso_media_rt.bin")
    File.write!(path, @bin)
    assert {:ok, boxes} = ISOMedia.read(path)
    out = Path.join(System.tmp_dir!(), "iso_media_rt_out.bin")
    assert :ok = ISOMedia.write(out, boxes)
    assert File.read!(out) == @bin
  after
    File.rm(Path.join(System.tmp_dir!(), "iso_media_rt.bin"))
    File.rm(Path.join(System.tmp_dir!(), "iso_media_rt_out.bin"))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media_test.exs`
Expected: FAIL — `ISOMedia.parse/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/iso_media.ex`:

```elixir
defmodule ISOMedia do
  @moduledoc """
  Lossless ISOBMFF (MP4/MOV/M4A/HEIF) box surgery.

      iex> {:ok, boxes} = ISOMedia.parse(<<8::32, "free">>)
      iex> ISOMedia.serialize(boxes)
      <<8::32, "free">>
  """

  alias ISOMedia.{Parser, Serializer}

  @doc "Parse a binary into `{:ok, [%ISOMedia.Box{}]}`. See `ISOMedia.Parser.parse/2`."
  def parse(binary, opts \\ []), do: Parser.parse(binary, opts)

  @doc "Serialize a box or list of boxes back to a binary."
  def serialize(boxes), do: Serializer.serialize(boxes)

  @doc "Read a file and parse it."
  def read(path, opts \\ []) do
    with {:ok, binary} <- File.read(path), do: parse(binary, opts)
  end

  @doc "Serialize boxes and write them to a file."
  def write(path, boxes), do: File.write(path, serialize(boxes))
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media_test.exs`
Expected: PASS (2 tests + doctest).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media.ex test/iso_media_test.exs
git commit -m "feat: add ISOMedia public API (parse/serialize/read/write)"
```

---

### Task 11: Box navigation — find / find_all

**Files:**
- Modify: `lib/iso_media/box.ex`
- Test: `test/iso_media/box_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/box_test.exs`:

```elixir
  describe "navigation" do
    setup do
      tree = [
        %Box{type: "ftyp", data: <<0>>},
        %Box{
          type: "moov",
          children: [
            %Box{type: "trak", children: [%Box{type: "tkhd", data: <<1>>}]},
            %Box{type: "trak", children: [%Box{type: "tkhd", data: <<2>>}]}
          ]
        }
      ]

      %{tree: tree}
    end

    test "find/2 returns the first match for a type-path", %{tree: tree} do
      assert %Box{type: "tkhd", data: <<1>>} = Box.find(tree, ~w(moov trak tkhd))
    end

    test "find/2 returns nil when nothing matches", %{tree: tree} do
      assert Box.find(tree, ~w(moov nope)) == nil
    end

    test "find_all/2 returns every match", %{tree: tree} do
      assert [%Box{data: <<1>>}, %Box{data: <<2>>}] = Box.find_all(tree, ~w(moov trak tkhd))
    end

    test "find_all/2 with a single-element path matches top level", %{tree: tree} do
      assert [%Box{type: "ftyp"}] = Box.find_all(tree, ~w(ftyp))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/box_test.exs`
Expected: FAIL — `ISOMedia.Box.find/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/iso_media/box.ex` (before the final `end`):

```elixir
  @doc "Return the first box matching the type-path, or `nil`."
  def find(boxes, path) when is_list(boxes), do: boxes |> find_all(path) |> List.first()

  @doc "Return every box matching the type-path."
  def find_all(boxes, [type]) when is_list(boxes) do
    Enum.filter(boxes, &(&1.type == type))
  end

  def find_all(boxes, [type | rest]) when is_list(boxes) do
    boxes
    |> Enum.filter(&(&1.type == type))
    |> Enum.flat_map(&find_all(&1.children, rest))
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/box_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/box.ex test/iso_media/box_test.exs
git commit -m "feat: path-based box navigation (find/find_all)"
```

---

### Task 12: Box editing — update / remove / insert / replace_data

**Files:**
- Modify: `lib/iso_media/box.ex`
- Test: `test/iso_media/box_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/iso_media/box_test.exs`:

```elixir
  describe "editing" do
    setup do
      tree = [
        %Box{
          type: "moov",
          children: [
            %Box{type: "trak", children: [%Box{type: "tkhd", data: <<1>>}]},
            %Box{type: "udta", children: []}
          ]
        }
      ]

      %{tree: tree}
    end

    test "update/3 applies fun to all matches", %{tree: tree} do
      updated = Box.update(tree, ~w(moov trak tkhd), &Box.replace_data(&1, <<9>>))
      assert %Box{data: <<9>>} = Box.find(updated, ~w(moov trak tkhd))
    end

    test "remove/2 cuts matching boxes out", %{tree: tree} do
      pruned = Box.remove(tree, ~w(moov udta))
      assert Box.find(pruned, ~w(moov udta)) == nil
      assert Box.find(pruned, ~w(moov trak)) != nil
    end

    test "insert/4 splices a box into the container at the path", %{tree: tree} do
      name = %Box{type: "name", data: "hi"}
      out = Box.insert(tree, ~w(moov udta), name, :end)
      assert [%Box{type: "name", data: "hi"}] = Box.find(out, ~w(moov udta)).children
    end

    test "insert/4 at :start prepends", %{tree: tree} do
      box = %Box{type: "free", data: ""}
      out = Box.insert(tree, ~w(moov), box, :start)
      assert %Box{type: "free"} = hd(Box.find(out, ~w(moov)).children)
    end

    test "replace_data/2 turns a box into a leaf with new bytes" do
      box = %Box{type: "moov", children: [%Box{type: "x"}]}
      assert %Box{data: <<7>>, children: []} = Box.replace_data(box, <<7>>)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/box_test.exs`
Expected: FAIL — `ISOMedia.Box.update/3 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/iso_media/box.ex` (before the final `end`):

```elixir
  @doc "Apply `fun` to every box matching the type-path; returns a new tree."
  def update(boxes, [type], fun) when is_list(boxes) do
    Enum.map(boxes, fn box ->
      if box.type == type, do: fun.(box), else: box
    end)
  end

  def update(boxes, [type | rest], fun) when is_list(boxes) do
    Enum.map(boxes, fn box ->
      if box.type == type and box.data == nil do
        %{box | children: update(box.children, rest, fun)}
      else
        box
      end
    end)
  end

  @doc "Remove every box matching the type-path; returns a new tree."
  def remove(boxes, [type]) when is_list(boxes) do
    Enum.reject(boxes, &(&1.type == type))
  end

  def remove(boxes, [type | rest]) when is_list(boxes) do
    Enum.map(boxes, fn box ->
      if box.type == type and box.data == nil do
        %{box | children: remove(box.children, rest)}
      else
        box
      end
    end)
  end

  @doc """
  Insert `new_box` into the children of the container found at `path`.
  `at` is `:start`, `:end`, or a zero-based integer index.
  """
  def insert(boxes, path, new_box, at \\ :end) when is_list(boxes) do
    update(boxes, path, fn container ->
      %{container | children: splice(container.children, new_box, at)}
    end)
  end

  defp splice(children, box, :end), do: children ++ [box]
  defp splice(children, box, :start), do: [box | children]

  defp splice(children, box, index) when is_integer(index) do
    {pre, post} = Enum.split(children, index)
    pre ++ [box] ++ post
  end

  @doc "Replace a box's payload, making it a leaf (drops any children)."
  def replace_data(%__MODULE__{} = box, binary) when is_binary(binary) do
    %{box | data: binary, children: []}
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/box_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/box.ex test/iso_media/box_test.exs
git commit -m "feat: immutable box editing (update/remove/insert/replace_data)"
```

---

### Task 13: FullBox header helper

**Files:**
- Create: `lib/iso_media/full_box.ex`
- Test: `test/iso_media/full_box_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/full_box_test.exs`:

```elixir
defmodule ISOMedia.FullBoxTest do
  use ExUnit.Case
  alias ISOMedia.FullBox

  test "parse/1 splits version, flags, and remaining payload" do
    assert {1, <<0, 0, 3>>, <<10, 20>>} = FullBox.parse(<<1, 0, 0, 3, 10, 20>>)
  end

  test "encode/3 rebuilds the prefix and round-trips with parse/1" do
    bin = IO.iodata_to_binary(FullBox.encode(1, <<0, 0, 3>>, <<10, 20>>))
    assert bin == <<1, 0, 0, 3, 10, 20>>
    assert {1, <<0, 0, 3>>, <<10, 20>>} = FullBox.parse(bin)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/full_box_test.exs`
Expected: FAIL — `ISOMedia.FullBox.parse/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/iso_media/full_box.ex`:

```elixir
defmodule ISOMedia.FullBox do
  @moduledoc """
  Helper for the `version` (1 byte) + `flags` (3 bytes) prefix that many
  ISOBMFF boxes (FullBoxes) carry before their payload.
  """

  @doc "Split a FullBox payload into `{version, flags, rest}`."
  def parse(<<version::8, flags::binary-size(3), rest::binary>>), do: {version, flags, rest}

  @doc "Build a FullBox payload iolist from version, flags, and the rest of the payload."
  def encode(version, <<_::24>> = flags, payload), do: [<<version::8>>, flags, payload]
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/full_box_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/full_box.ex test/iso_media/full_box_test.exs
git commit -m "feat: add FullBox version/flags helper"
```

---

### Task 14: Typed view — FileType (`ftyp`)

**Files:**
- Create: `lib/iso_media/boxes/file_type.ex`
- Test: `test/iso_media/boxes/file_type_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/boxes/file_type_test.exs`:

```elixir
defmodule ISOMedia.Boxes.FileTypeTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.FileType

  @data <<"isom", 512::32, "isom", "iso2", "mp41">>

  test "decode/1 extracts brands and minor version" do
    ft = FileType.decode(%Box{type: "ftyp", data: @data})
    assert ft.major_brand == "isom"
    assert ft.minor_version == 512
    assert ft.compatible_brands == ["isom", "iso2", "mp41"]
  end

  test "encode/1 round-trips back to the original box data" do
    box = %Box{type: "ftyp", data: @data}
    assert FileType.encode(FileType.decode(box)) == box
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/boxes/file_type_test.exs`
Expected: FAIL — `ISOMedia.Boxes.FileType.decode/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/iso_media/boxes/file_type.ex`:

```elixir
defmodule ISOMedia.Boxes.FileType do
  @moduledoc "Typed view of the `ftyp` File Type Box."

  alias ISOMedia.Box

  defstruct [:major_brand, :minor_version, :compatible_brands]

  @type t :: %__MODULE__{
          major_brand: String.t(),
          minor_version: non_neg_integer(),
          compatible_brands: [String.t()]
        }

  @doc "Decode an `ftyp` box into a `%FileType{}`."
  def decode(%Box{type: "ftyp", data: <<major::binary-size(4), minor::32, rest::binary>>}) do
    %__MODULE__{
      major_brand: major,
      minor_version: minor,
      compatible_brands: for(<<b::binary-size(4) <- rest>>, do: b)
    }
  end

  @doc "Encode a `%FileType{}` back into an `ftyp` box."
  def encode(%__MODULE__{} = ft) do
    data = IO.iodata_to_binary([ft.major_brand, <<ft.minor_version::32>>, ft.compatible_brands])
    %Box{type: "ftyp", data: data}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/boxes/file_type_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/boxes/file_type.ex test/iso_media/boxes/file_type_test.exs
git commit -m "feat: typed view for ftyp (FileType)"
```

---

### Task 15: Typed view — Handler (`hdlr`)

**Files:**
- Create: `lib/iso_media/boxes/handler.ex`
- Test: `test/iso_media/boxes/handler_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/boxes/handler_test.exs`:

```elixir
defmodule ISOMedia.Boxes.HandlerTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.Handler

  # FullBox(v0,flags0) + pre_defined(0) + handler "vide" + 3x reserved + name "VideoHandler\0"
  @data <<0, 0, 0, 0, 0::32, "vide", 0::32, 0::32, 0::32, "VideoHandler", 0>>

  test "decode/1 extracts handler_type and name (name strips trailing NUL)" do
    h = Handler.decode(%Box{type: "hdlr", data: @data})
    assert h.handler_type == "vide"
    assert h.name == "VideoHandler"
    assert h.version == 0
  end

  test "encode/1 round-trips back to the original box data" do
    box = %Box{type: "hdlr", data: @data}
    assert Handler.encode(Handler.decode(box)) == box
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/boxes/handler_test.exs`
Expected: FAIL — `ISOMedia.Boxes.Handler.decode/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/iso_media/boxes/handler.ex`:

```elixir
defmodule ISOMedia.Boxes.Handler do
  @moduledoc """
  Typed view of the `hdlr` Handler Reference Box.

  Layout (FullBox): pre_defined(32) · handler_type(4) · reserved(32)x3 ·
  name (UTF-8, NUL-terminated, to end of box).

  `name` is exposed without its trailing NUL; the original terminator is
  reproduced on encode.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :flags, :handler_type, :name]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          flags: <<_::24>>,
          handler_type: String.t(),
          name: String.t()
        }

  @doc "Decode an `hdlr` box into a `%Handler{}`."
  def decode(%Box{type: "hdlr", data: data}) do
    {version, flags, body} = FullBox.parse(data)

    <<_pre_defined::32, handler_type::binary-size(4), _reserved::binary-size(12), name_field::binary>> =
      body

    %__MODULE__{
      version: version,
      flags: flags,
      handler_type: handler_type,
      name: strip_nul(name_field)
    }
  end

  @doc "Encode a `%Handler{}` back into an `hdlr` box."
  def encode(%__MODULE__{} = h) do
    body = [<<0::32>>, h.handler_type, <<0::32, 0::32, 0::32>>, h.name, <<0>>]
    data = IO.iodata_to_binary(FullBox.encode(h.version, h.flags, body))
    %Box{type: "hdlr", data: data}
  end

  defp strip_nul(bin) do
    case :binary.split(bin, <<0>>) do
      [name | _] -> name
      [] -> ""
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/boxes/handler_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/boxes/handler.ex test/iso_media/boxes/handler_test.exs
git commit -m "feat: typed view for hdlr (Handler)"
```

---

### Task 16: Typed views — MovieHeader / TrackHeader / MediaHeader

These three are FullBoxes whose leading fields are version-dependent. Each exposes
the headline fields and keeps the remaining payload as a raw `rest` binary, which
guarantees a byte-perfect round-trip without transcribing every trailing field
(rate, volume, matrix, etc.).

**Files:**
- Create: `lib/iso_media/boxes/movie_header.ex`
- Create: `lib/iso_media/boxes/track_header.ex`
- Create: `lib/iso_media/boxes/media_header.ex`
- Test: `test/iso_media/boxes/headers_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/boxes/headers_test.exs`:

```elixir
defmodule ISOMedia.Boxes.HeadersTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.{MovieHeader, TrackHeader, MediaHeader}

  test "MovieHeader v0 decodes timescale/duration and round-trips" do
    # FullBox(v0) + ctime,mtime,timescale,duration (32 each) + trailing rest
    data = <<0, 0, 0, 0, 100::32, 200::32, 600::32, 1200::32, 0xAA, 0xBB>>
    box = %Box{type: "mvhd", data: data}
    h = MovieHeader.decode(box)
    assert h.timescale == 600
    assert h.duration == 1200
    assert h.creation_time == 100
    assert MovieHeader.encode(h) == box
  end

  test "MovieHeader v1 uses 64-bit times/duration and round-trips" do
    data = <<1, 0, 0, 0, 100::64, 200::64, 600::32, 1200::64, 0xCC>>
    box = %Box{type: "mvhd", data: data}
    h = MovieHeader.decode(box)
    assert h.version == 1
    assert h.timescale == 600
    assert h.duration == 1200
    assert MovieHeader.encode(h) == box
  end

  test "TrackHeader v0 decodes track_id/duration and round-trips" do
    # ctime,mtime,track_ID,reserved,duration + rest
    data = <<0, 0, 0, 7, 100::32, 200::32, 3::32, 0::32, 1200::32, 0xEE>>
    box = %Box{type: "tkhd", data: data}
    h = TrackHeader.decode(box)
    assert h.track_id == 3
    assert h.duration == 1200
    assert h.flags == <<0, 0, 7>>
    assert TrackHeader.encode(h) == box
  end

  test "MediaHeader v0 decodes timescale/duration and round-trips" do
    data = <<0, 0, 0, 0, 100::32, 200::32, 600::32, 1200::32, 0x15, 0xC7, 0, 0>>
    box = %Box{type: "mdhd", data: data}
    h = MediaHeader.decode(box)
    assert h.timescale == 600
    assert h.duration == 1200
    assert MediaHeader.encode(h) == box
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/boxes/headers_test.exs`
Expected: FAIL — `ISOMedia.Boxes.MovieHeader.decode/1 is undefined`.

- [ ] **Step 3: Write the three implementations**

Create `lib/iso_media/boxes/movie_header.ex`:

```elixir
defmodule ISOMedia.Boxes.MovieHeader do
  @moduledoc """
  Typed view of the `mvhd` Movie Header Box. Exposes `timescale`/`duration`
  (and creation/modification times); all trailing fields (rate, volume, matrix,
  next_track_ID, ...) are preserved verbatim in `rest`.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :flags, :creation_time, :modification_time, :timescale, :duration, :rest]

  def decode(%Box{type: "mvhd", data: data}) do
    {version, flags, body} = FullBox.parse(data)
    {ctime, mtime, timescale, duration, rest} = split(version, body)

    %__MODULE__{
      version: version,
      flags: flags,
      creation_time: ctime,
      modification_time: mtime,
      timescale: timescale,
      duration: duration,
      rest: rest
    }
  end

  def encode(%__MODULE__{version: 0} = h) do
    body = [<<h.creation_time::32, h.modification_time::32, h.timescale::32, h.duration::32>>, h.rest]
    wrap(h, body)
  end

  def encode(%__MODULE__{version: 1} = h) do
    body = [<<h.creation_time::64, h.modification_time::64, h.timescale::32, h.duration::64>>, h.rest]
    wrap(h, body)
  end

  defp split(0, <<c::32, m::32, ts::32, d::32, rest::binary>>), do: {c, m, ts, d, rest}
  defp split(1, <<c::64, m::64, ts::32, d::64, rest::binary>>), do: {c, m, ts, d, rest}

  defp wrap(h, body) do
    %Box{type: "mvhd", data: IO.iodata_to_binary(FullBox.encode(h.version, h.flags, body))}
  end
end
```

Create `lib/iso_media/boxes/track_header.ex`:

```elixir
defmodule ISOMedia.Boxes.TrackHeader do
  @moduledoc """
  Typed view of the `tkhd` Track Header Box. Exposes `track_id`/`duration`
  (and creation/modification times); trailing fields are preserved in `rest`.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :flags, :creation_time, :modification_time, :track_id, :duration, :rest]

  def decode(%Box{type: "tkhd", data: data}) do
    {version, flags, body} = FullBox.parse(data)
    {ctime, mtime, track_id, duration, rest} = split(version, body)

    %__MODULE__{
      version: version,
      flags: flags,
      creation_time: ctime,
      modification_time: mtime,
      track_id: track_id,
      duration: duration,
      rest: rest
    }
  end

  def encode(%__MODULE__{version: 0} = h) do
    body = [<<h.creation_time::32, h.modification_time::32, h.track_id::32, 0::32, h.duration::32>>, h.rest]
    wrap(h, body)
  end

  def encode(%__MODULE__{version: 1} = h) do
    body = [<<h.creation_time::64, h.modification_time::64, h.track_id::32, 0::32, h.duration::64>>, h.rest]
    wrap(h, body)
  end

  defp split(0, <<c::32, m::32, id::32, _res::32, d::32, rest::binary>>), do: {c, m, id, d, rest}
  defp split(1, <<c::64, m::64, id::32, _res::32, d::64, rest::binary>>), do: {c, m, id, d, rest}

  defp wrap(h, body) do
    %Box{type: "tkhd", data: IO.iodata_to_binary(FullBox.encode(h.version, h.flags, body))}
  end
end
```

Create `lib/iso_media/boxes/media_header.ex`:

```elixir
defmodule ISOMedia.Boxes.MediaHeader do
  @moduledoc """
  Typed view of the `mdhd` Media Header Box. Exposes `timescale`/`duration`
  (and creation/modification times); the trailing language + pre_defined fields
  are preserved in `rest`.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :flags, :creation_time, :modification_time, :timescale, :duration, :rest]

  def decode(%Box{type: "mdhd", data: data}) do
    {version, flags, body} = FullBox.parse(data)
    {ctime, mtime, timescale, duration, rest} = split(version, body)

    %__MODULE__{
      version: version,
      flags: flags,
      creation_time: ctime,
      modification_time: mtime,
      timescale: timescale,
      duration: duration,
      rest: rest
    }
  end

  def encode(%__MODULE__{version: 0} = h) do
    body = [<<h.creation_time::32, h.modification_time::32, h.timescale::32, h.duration::32>>, h.rest]
    wrap(h, body)
  end

  def encode(%__MODULE__{version: 1} = h) do
    body = [<<h.creation_time::64, h.modification_time::64, h.timescale::32, h.duration::64>>, h.rest]
    wrap(h, body)
  end

  defp split(0, <<c::32, m::32, ts::32, d::32, rest::binary>>), do: {c, m, ts, d, rest}
  defp split(1, <<c::64, m::64, ts::32, d::64, rest::binary>>), do: {c, m, ts, d, rest}

  defp wrap(h, body) do
    %Box{type: "mdhd", data: IO.iodata_to_binary(FullBox.encode(h.version, h.flags, body))}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/boxes/headers_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/boxes/movie_header.ex lib/iso_media/boxes/track_header.ex lib/iso_media/boxes/media_header.ex test/iso_media/boxes/headers_test.exs
git commit -m "feat: typed views for mvhd/tkhd/mdhd headers"
```

---

### Task 17: Real-file fixtures + round-trip on real media

**Files:**
- Create: `test/fixtures/sample.mp4`, `test/fixtures/sample.m4a` (generated)
- Create: `test/fixtures/README.md`
- Create: `test/iso_media/fixtures_test.exs`

- [ ] **Step 1: Generate tiny real fixtures with ffmpeg**

Run:
```bash
mkdir -p test/fixtures
ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 \
  -pix_fmt yuv420p test/fixtures/sample.mp4
ffmpeg -y -f lavfi -i sine=frequency=440:duration=1 \
  -c:a aac test/fixtures/sample.m4a
```
Expected: two small files created (each well under ~100 KB). Verify:
```bash
ls -la test/fixtures/*.mp4 test/fixtures/*.m4a
```

- [ ] **Step 2: Write a note about regenerating fixtures**

Create `test/fixtures/README.md`:

```markdown
# Test fixtures

Tiny ISOBMFF files used for round-trip tests. Regenerate with:

    ffmpeg -y -f lavfi -i testsrc=duration=1:size=128x96:rate=10 -pix_fmt yuv420p sample.mp4
    ffmpeg -y -f lavfi -i sine=frequency=440:duration=1 -c:a aac sample.m4a
```

- [ ] **Step 3: Write the failing test**

Create `test/iso_media/fixtures_test.exs`:

```elixir
defmodule ISOMedia.FixturesTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.FileType

  @fixtures Path.wildcard(Path.join([__DIR__, "..", "fixtures", "*.{mp4,m4a}"]))

  test "fixtures exist" do
    assert @fixtures != [], "expected generated fixtures in test/fixtures (run ffmpeg step)"
  end

  for path <- @fixtures do
    @path path

    test "round-trips real file byte-for-byte: #{Path.basename(path)}" do
      original = File.read!(@path)
      {:ok, boxes} = ISOMedia.parse(original)
      assert ISOMedia.serialize(boxes) == original
    end

    test "has a top-level ftyp that decodes: #{Path.basename(path)}" do
      {:ok, boxes} = ISOMedia.parse(File.read!(@path))
      ftyp = Box.find(boxes, ~w(ftyp))
      assert %Box{type: "ftyp"} = ftyp
      decoded = FileType.decode(ftyp)
      assert byte_size(decoded.major_brand) == 4
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/fixtures_test.exs`
Expected: PASS — every fixture round-trips and exposes a decodable `ftyp`. (If round-trip fails, the parser/serializer has a real-world gap; debug with `superpowers:systematic-debugging` before continuing.)

- [ ] **Step 5: Commit**

```bash
git add test/fixtures test/iso_media/fixtures_test.exs
git commit -m "test: round-trip real ffmpeg-generated fixtures"
```

---

### Task 18: Property-based round-trip over generated trees

**Files:**
- Create: `test/iso_media/roundtrip_property_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/roundtrip_property_test.exs`:

```elixir
defmodule ISOMedia.RoundtripPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.{Box, Serializer, Parser}

  # A printable 4-char type that is NOT a known container, so the parser keeps
  # it as a leaf and round-trips deterministically.
  defp leaf_type do
    gen all <<a, b, c, d>> <- binary(length: 4),
            type = <<rescale(a), rescale(b), rescale(c), rescale(d)>>,
            not ISOMedia.Registry.container?(type) do
      type
    end
  end

  # map a byte into the printable ASCII range 0x41..0x5A (A-Z)
  defp rescale(byte), do: 0x41 + rem(byte, 26)

  defp leaf_box do
    gen all type <- leaf_type(),
            data <- binary(max_length: 32) do
      %Box{type: type, data: data, size_mode: :compact}
    end
  end

  defp container_box do
    gen all type <- leaf_type(),
            kids <- list_of(leaf_box(), max_length: 3) do
      %Box{type: type, data: nil, children: kids, size_mode: :compact}
    end
  end

  property "serialize |> parse is identity for generated trees" do
    check all boxes <- list_of(one_of([leaf_box(), container_box()]), max_length: 5) do
      bin = Serializer.serialize(boxes)
      assert {:ok, parsed} = Parser.parse(bin, heuristic: false)
      assert Serializer.serialize(parsed) == bin
    end
  end
end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/iso_media/roundtrip_property_test.exs`
Expected: PASS — `serialize` then `serialize∘parse` are stable. (A container with a generated leaf type isn't in the registry, so without `:heuristic` it re-parses as a leaf; the test asserts serialize-stability, i.e. `serialize(parse(serialize(t))) == serialize(t)`, which is the meaningful invariant here.)

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: PASS — all tests across the project.

- [ ] **Step 4: Commit**

```bash
git add test/iso_media/roundtrip_property_test.exs
git commit -m "test: property-based round-trip over generated box trees"
```

---

### Task 19: README + module docs polish

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md` (remove the "Known issues" section now that they're fixed)

- [ ] **Step 1: Rewrite `README.md`**

Overwrite `README.md`:

```markdown
# ISOMedia

Lossless ISOBMFF (MP4 / MOV / M4A / HEIF) box surgery in pure Elixir.

Parse any ISO Base Media file into a tree of boxes — every box, including
unknown/vendor boxes, preserved byte-for-byte — then navigate, extract, reorder,
insert, edit, and re-serialize.

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")

# inspect
ISOMedia.Box.find(boxes, ~w(moov mvhd))
ISOMedia.Boxes.FileType.decode(ISOMedia.Box.find(boxes, ~w(ftyp)))

# edit (immutable — returns a new tree)
boxes = ISOMedia.Box.remove(boxes, ~w(moov udta))

# write back out
ISOMedia.write("out.mp4", boxes)
```

## Status

Phase 1: lossless tree surgery. The library does **not** yet rewrite absolute
offset tables (`stco`/`co64`) on edit — moving data those tables reference is the
caller's responsibility. See `docs/superpowers/specs/` for the design.
```

- [ ] **Step 2: Trim the obsolete "Known issues" from `CLAUDE.md`**

In `CLAUDE.md`, delete the entire `## Known issues / gotchas` section (those bugs are fixed) and update the architecture section to point at `lib/iso_media/parser.ex`, `serializer.ex`, `box.ex`, `registry.ex`, and `boxes/`.

- [ ] **Step 3: Verify docs build (optional sanity)**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document box-surgery API and update CLAUDE.md"
```

---

## Self-Review Notes

- **Spec coverage:** generic Box struct (T2), hybrid registry+heuristic recursion (T3, T9), parser incl. largesize/eof/uuid (T4–T7), byte-perfect serializer (T8), public API (T10), navigation/editing (T11–T12), FullBox helper (T13), typed views ftyp/hdlr/mvhd/tkhd/mdhd (T14–T16), fixtures + real-file round-trip (T17), property round-trip (T18), cleanup of old Ecto files + `:fs` removal + naming (T1), docs (T19). Out-of-scope items (offset fixup, lazy payloads, full box coverage) are intentionally excluded.
- **Type consistency:** `%Box{type, data, children, uuid, size_mode}` used identically throughout; `size_mode` values `:compact|:large|:eof` consistent between parser and serializer; typed views all follow `decode/1`→struct, `encode/1`→`%Box{}`.
- **Placeholders:** none — every code/test step contains complete content.
