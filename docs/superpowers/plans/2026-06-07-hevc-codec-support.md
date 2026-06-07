# HEVC (hvc1/hev1) Codec Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decode HEVC (`hvc1`/`hev1`) video sample entries in `ISOMedia.Codec` so `track_info/2` returns an RFC 6381 codec string (`hvc1.1.6.L93.B0`) plus width/height, unblocking HLS/DASH manifest generation on HEVC content.

**Architecture:** Mirror the existing `avc1` path in `lib/iso_media/codec.ex` — a public `hvc1_codec/2` helper (unit-testable like `avc1_codec/1`/`mp4a_codec/1`), a private `reverse_32_bits/1` (1-bit binary pattern match, no `Bitwise`), and two `parse_entry/3` clauses for `hvc1`/`hev1`. The core parser/Registry are untouched, so the byte-for-byte round-trip invariant holds (we only read inside the opaque `stsd`).

**Tech Stack:** Elixir, ExUnit. Optional `ffmpeg` (HEVC encoder) for the integration fixture.

**Spec:** `docs/superpowers/specs/2026-06-07-hevc-codec-support-design.md`

---

## File structure

- **Modify** `lib/iso_media/codec.ex` — add `hvc1_codec/2` (public), `reverse_32_bits/1` (private), and `hvc1`/`hev1` `parse_entry/3` clauses; extend the truncation guard list.
- **Modify** `test/iso_media/codec_test.exs` — add HEVC unit + integration tests; fix the existing `unsupported codec hvc1` test (swap to a still-unsupported fourcc).
- **Create** `test/fixtures/sample_hevc.mp4` — small neutral HEVC clip for the integration test.

---

## Task 1: `hvc1_codec/2` + `reverse_32_bits/1` (the RFC 6381 string — primary gate)

**Files:**
- Modify: `lib/iso_media/codec.ex`
- Test: `test/iso_media/codec_test.exs`

- [ ] **Step 1: Write the failing unit tests**

Add this `describe` block to `test/iso_media/codec_test.exs` (after the `find_sub_box/2` block, before the `track_info/2 — video (avc1)` block):

```elixir
  describe "hvc1_codec/2" do
    # hvcC HEVCDecoderConfigurationRecord (first 13 bytes):
    #   config_version | profile_space(2)/tier(1)/profile_idc(5) | compat(32)
    #   | constraint(48, 6 bytes) | level_idc | trailers...
    # Main profile, level 3.1 (93), one constraint byte 0xB0:
    #   profile_idc=1 -> byte1 0x01; compat 0x60000000 reverses to 0x6.
    defp main_hvcc(level \\ 93) do
      <<1, 0x01, 0x60, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, level, 0xFF, 0xFF>>
    end

    test "Main profile, level 3.1 -> hvc1.1.6.L93.B0" do
      assert ISOMedia.Codec.hvc1_codec("hvc1", main_hvcc()) == "hvc1.1.6.L93.B0"
    end

    test "hev1 fourcc is preserved as the prefix" do
      assert ISOMedia.Codec.hvc1_codec("hev1", main_hvcc()) == "hev1.1.6.L93.B0"
    end

    test "compatibility flags are bit-reversed, uppercase hex, leading zeros dropped" do
      # compat 0x00000001 (only bit 0) reverses to 0x80000000 -> "80000000"
      rec = <<1, 0x01, 0x00, 0x00, 0x00, 0x01, 0xB0, 0, 0, 0, 0, 0, 93, 0xFF>>
      assert ISOMedia.Codec.hvc1_codec("hvc1", rec) == "hvc1.1.80000000.L93.B0"
    end

    test "multiple non-zero constraint bytes are dot-joined (%02X), trailing zeros dropped" do
      # constraint bytes 0x90, 0x80, then zeros -> "90.80"
      rec = <<1, 0x01, 0x60, 0, 0, 0, 0x90, 0x80, 0, 0, 0, 0, 93>>
      assert ISOMedia.Codec.hvc1_codec("hvc1", rec) == "hvc1.1.6.L93.90.80"
    end

    test "all-zero constraint flags omit the constraint section entirely" do
      rec = <<1, 0x01, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 93>>
      assert ISOMedia.Codec.hvc1_codec("hvc1", rec) == "hvc1.1.6.L93"
    end

    test "profile_space 1 prefixes the profile with A; high tier uses H" do
      # byte1: space=1 (01), tier=1 (1), idc=2 (00010) -> 0b01_1_00010 = 0x62; level 120
      rec = <<1, 0x62, 0x60, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 120>>
      assert ISOMedia.Codec.hvc1_codec("hvc1", rec) == "hvc1.A2.6.H120.B0"
    end

    test "raises on an hvcC record shorter than 13 bytes" do
      assert_raise ArgumentError, ~r/hvcC/, fn ->
        ISOMedia.Codec.hvc1_codec("hvc1", <<1, 0x01, 0x60, 0x00>>)
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/iso_media/codec_test.exs`
Expected: FAIL — `(UndefinedFunctionError) function ISOMedia.Codec.hvc1_codec/2 is undefined`.

- [ ] **Step 3: Implement `hvc1_codec/2` and `reverse_32_bits/1`**

In `lib/iso_media/codec.ex`, add these immediately after the `avc1_codec/1` function (the block ending at the line `"avc1." <> Base.encode16(<<profile, compat, level>>, case: :lower)` / its closing `end`, around line 90):

```elixir
  @doc """
  Build an RFC 6381 HEVC codec string (`hvc1.*` / `hev1.*`) from `fourcc` and an `hvcC`
  HEVCDecoderConfigurationRecord payload: profile (with profile-space prefix), the
  bit-reversed compatibility flags (uppercase hex, leading zeros dropped), `L`/`H` tier +
  level, and the constraint bytes (`%02X`, trailing-zero bytes omitted). Raises on a record
  shorter than 13 bytes.
  """
  @spec hvc1_codec(binary(), binary()) :: String.t()
  def hvc1_codec(fourcc, <<
        _config_version::8,
        profile_space::2,
        tier_flag::1,
        profile_idc::5,
        compat_flags::32,
        c1::8,
        c2::8,
        c3::8,
        c4::8,
        c5::8,
        c6::8,
        level_idc::8,
        _rest::binary
      >>) do
    space =
      case profile_space do
        0 -> ""
        1 -> "A"
        2 -> "B"
        3 -> "C"
      end

    profile = "#{space}#{profile_idc}"
    compat = compat_flags |> reverse_32_bits() |> Integer.to_string(16)
    tier_level = "#{if tier_flag == 1, do: "H", else: "L"}#{level_idc}"

    constraints =
      [c1, c2, c3, c4, c5, c6]
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == 0))
      |> Enum.reverse()
      |> Enum.map(&String.pad_leading(Integer.to_string(&1, 16), 2, "0"))

    Enum.join([fourcc, profile, compat, tier_level | constraints], ".")
  end

  def hvc1_codec(_fourcc, _payload) do
    raise ArgumentError, "track_info: truncated or invalid hvcC payload"
  end

  # Reverse the 32 compatibility-flag bits via a 1-bit binary match (no Bitwise).
  defp reverse_32_bits(val) do
    <<b01::1, b02::1, b03::1, b04::1, b05::1, b06::1, b07::1, b08::1, b09::1, b10::1, b11::1,
      b12::1, b13::1, b14::1, b15::1, b16::1, b17::1, b18::1, b19::1, b20::1, b21::1, b22::1,
      b23::1, b24::1, b25::1, b26::1, b27::1, b28::1, b29::1, b30::1, b31::1, b32::1>> =
      <<val::32>>

    <<reversed::32>> =
      <<b32::1, b31::1, b30::1, b29::1, b28::1, b27::1, b26::1, b25::1, b24::1, b23::1, b22::1,
        b21::1, b20::1, b19::1, b18::1, b17::1, b16::1, b15::1, b14::1, b13::1, b12::1, b11::1,
        b10::1, b09::1, b08::1, b07::1, b06::1, b05::1, b04::1, b03::1, b02::1, b01::1>>

    reversed
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/iso_media/codec_test.exs`
Expected: PASS (all the `hvc1_codec/2` tests green).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/codec.ex test/iso_media/codec_test.exs
git commit -m "feat: HEVC hvc1_codec/2 RFC 6381 codec-string builder"
```

---

## Task 2: Wire `hvc1`/`hev1` into `parse_entry/3`

**Files:**
- Modify: `lib/iso_media/codec.ex`
- Test: `test/iso_media/codec_test.exs`

- [ ] **Step 1: Write the failing test (full hand-built HEVC trak — ffmpeg-independent)**

Add this `describe` block to `test/iso_media/codec_test.exs` (after the `track_info/2 — video (avc1)` block):

```elixir
  describe "track_info/2 — video (hvc1/hev1)" do
    # A full VisualSampleEntry (86-byte header: width@32, height@34, children@86) wrapping an
    # hvcC box, mirroring the hand-built-trak idiom used by the unsupported-codec test below.
    defp hevc_trak(fourcc) do
      hvcc_record = <<1, 0x01, 0x60, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 93, 0xFF, 0xFF>>
      hvcc_box = <<byte_size(hvcc_record) + 8::32, "hvcC", hvcc_record::binary>>

      entry_body =
        <<0::48, 1::16, 0::16, 0::16, 0::96, 320::16, 240::16, 0::32, 0::32, 0::32, 0::16,
          0::256, 0x18::16, 0xFFFF::16>> <> hvcc_box

      entry = <<byte_size(entry_body) + 8::32, fourcc::binary>> <> entry_body
      stsd = %ISOMedia.Box{type: "stsd", data: <<0::8, 0::24, 1::32>> <> entry}

      tkhd = %ISOMedia.Box{
        type: "tkhd",
        data: <<0::8, 0::24, 0::32, 0::32, 1::32, 0::32, 0::32, 0::480>>
      }

      mdhd = %ISOMedia.Box{
        type: "mdhd",
        data: <<0::8, 0::24, 0::32, 0::32, 15360::32, 0::32, 0x55C4::16, 0::16>>
      }

      stbl = %ISOMedia.Box{type: "stbl", children: [stsd]}
      minf = %ISOMedia.Box{type: "minf", children: [stbl]}
      mdia = %ISOMedia.Box{type: "mdia", children: [mdhd, minf]}
      trak = %ISOMedia.Box{type: "trak", children: [tkhd, mdia]}
      [%ISOMedia.Box{type: "moov", children: [trak]}]
    end

    test "decodes an hvc1 sample entry to codec string + dimensions" do
      info = ISOMedia.track_info(hevc_trak("hvc1"), 1)
      assert info.type == :video
      assert info.format == "hvc1"
      assert info.codec == "hvc1.1.6.L93.B0"
      assert info.width == 320
      assert info.height == 240
      assert info.timescale == 15360
    end

    test "decodes an hev1 sample entry, preserving the hev1 prefix" do
      info = ISOMedia.track_info(hevc_trak("hev1"), 1)
      assert info.format == "hev1"
      assert info.codec == "hev1.1.6.L93.B0"
      assert info.type == :video
    end

    test "raises on a truncated hvc1 sample entry (shorter than 86 bytes)" do
      stsd = %ISOMedia.Box{type: "stsd", data: <<0::8, 0::24, 1::32, 16::32, "hvc1", 0::64>>}
      tkhd = %ISOMedia.Box{
        type: "tkhd",
        data: <<0::8, 0::24, 0::32, 0::32, 1::32, 0::32, 0::32, 0::480>>
      }

      mdhd = %ISOMedia.Box{
        type: "mdhd",
        data: <<0::8, 0::24, 0::32, 0::32, 1000::32, 0::32, 0x55C4::16, 0::16>>
      }

      stbl = %ISOMedia.Box{type: "stbl", children: [stsd]}
      minf = %ISOMedia.Box{type: "minf", children: [stbl]}
      mdia = %ISOMedia.Box{type: "mdia", children: [mdhd, minf]}
      trak = %ISOMedia.Box{type: "trak", children: [tkhd, mdia]}

      assert_raise ArgumentError, ~r/truncated hvc1/, fn ->
        ISOMedia.track_info([%ISOMedia.Box{type: "moov", children: [trak]}], 1)
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/iso_media/codec_test.exs`
Expected: FAIL — the hvc1/hev1 tests raise `unsupported codec hvc1`/`hev1` (no `parse_entry` clause yet).

- [ ] **Step 3: Add the `hvc1`/`hev1` `parse_entry/3` clauses and extend the truncation guard**

In `lib/iso_media/codec.ex`, find the `mp4a` `parse_entry/3` clause (the one matching `"mp4a"` with `byte_size(entry) >= 36`, ending around line 203). Immediately after it, add:

```elixir
  # HEVC VisualSampleEntry: same layout as avc1 (width@32, height@34, child boxes@86).
  defp parse_entry(fmt, entry, base) when fmt in ["hvc1", "hev1"] and byte_size(entry) >= 86 do
    <<_::binary-size(32), width::16, height::16, _::binary>> = entry
    <<_::binary-size(86), children::binary>> = entry
    codec = hvc1_codec(fmt, find_sub_box(children, "hvcC"))
    %{base | type: :video, codec: codec, width: width, height: height}
  end
```

Then change the truncation clause (currently `when format in ["avc1", "mp4a"]`) to include the HEVC fourccs:

```elixir
  defp parse_entry(format, entry, _base) when format in ["avc1", "mp4a", "hvc1", "hev1"] do
    raise ArgumentError,
          "track_info: truncated #{format} sample entry (#{byte_size(entry)} bytes)"
  end
```

- [ ] **Step 4: Fix the existing `unsupported codec` test (it used `hvc1`, now supported)**

In `test/iso_media/codec_test.exs`, the test `"raises on an unsupported codec format"` builds a `stsd` with `"hvc1"` and asserts `~r/unsupported codec hvc1/`. Since `hvc1` is now supported, change that fourcc to one that is still unsupported. Replace the `stsd` line:

```elixir
      stsd = %ISOMedia.Box{type: "stsd", data: <<0::8, 0::24, 1::32, 16::32, "hvc1", 0::64>>}
```

with:

```elixir
      stsd = %ISOMedia.Box{type: "stsd", data: <<0::8, 0::24, 1::32, 16::32, "av01", 0::64>>}
```

and the assertion regex `~r/unsupported codec hvc1/` with `~r/unsupported codec av01/`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/iso_media/codec_test.exs`
Expected: PASS (hvc1/hev1 decode, truncation raise, and the updated `av01` unsupported test all green).

- [ ] **Step 6: Commit**

```bash
git add lib/iso_media/codec.ex test/iso_media/codec_test.exs
git commit -m "feat: decode hvc1/hev1 sample entries in track_info/2"
```

---

## Task 3: HEVC fixture + integration test (real bytes + HLS/DASH unblocking + round-trip)

**Files:**
- Create: `test/fixtures/sample_hevc.mp4`
- Test: `test/iso_media/codec_test.exs`

- [ ] **Step 1: Generate a small neutral HEVC fixture**

Try `libx265` first (portable output, explicit `hvc1` tag):

Run:
```bash
ffmpeg -y -f lavfi -i testsrc=duration=1:size=320x240:rate=30 \
  -c:v libx265 -profile:v main -pix_fmt yuv420p -tag:v hvc1 \
  test/fixtures/sample_hevc.mp4
```

If that fails with "Unknown encoder 'libx265'", use macOS hardware HEVC instead:
```bash
ffmpeg -y -f lavfi -i testsrc=duration=1:size=320x240:rate=30 \
  -c:v hevc_videotoolbox -pix_fmt yuv420p -tag:v hvc1 \
  test/fixtures/sample_hevc.mp4
```

Expected: `test/fixtures/sample_hevc.mp4` exists and is small (well under 200 KB).
If neither encoder is available, STOP and report BLOCKED — the unit tests in Tasks 1–2 are the correctness gate, but this fixture step needs an HEVC encoder.

- [ ] **Step 2: Probe the fixture to capture its real codec string**

Run:
```bash
mix run -e '{:ok, b} = ISOMedia.read("test/fixtures/sample_hevc.mp4"); tid = Enum.find(ISOMedia.track_ids(b), fn t -> ISOMedia.track_info(b, t).type == :video end); IO.inspect(ISOMedia.track_info(b, tid).codec, label: "video codec")'
```
Expected: prints something like `video codec: "hvc1.1.6.L93.B0"` (the exact level/constraint values depend on the encoder). **Record this exact string** — it is pinned in the next step's test.

- [ ] **Step 3: Write the failing integration test**

Add this `describe` block to `test/iso_media/codec_test.exs` (after the hvc1/hev1 block from Task 2). Replace `PINNED_CODEC` with the exact string printed in Step 2:

```elixir
  describe "HEVC fixture integration" do
    defp hevc_video_tid(boxes) do
      Enum.find(ISOMedia.track_ids(boxes), fn tid ->
        ISOMedia.track_info(boxes, tid).type == :video
      end)
    end

    test "track_info decodes the real HEVC fixture" do
      {:ok, b} = ISOMedia.read("test/fixtures/sample_hevc.mp4")
      info = ISOMedia.track_info(b, hevc_video_tid(b))
      assert info.type == :video
      assert info.format == "hvc1"
      assert info.codec == "PINNED_CODEC"
      assert info.width == 320
      assert info.height == 240
    end

    test "HEVC unblocks HLS master and DASH manifests (previously raised)" do
      {:ok, b} = ISOMedia.read("test/fixtures/sample_hevc.mp4")
      frag = ISOMedia.fragment(b, target_duration: 0.5)
      assert ISOMedia.hls_master_playlist(frag) =~ ~s(CODECS="hvc1.)
      assert ISOMedia.dash_manifest(frag) =~ ~s(codecs="hvc1.)
    end

    test "track_info does not disturb the HEVC fixture's byte-for-byte round trip" do
      bin = File.read!("test/fixtures/sample_hevc.mp4")
      {:ok, b} = ISOMedia.parse(bin)
      _ = ISOMedia.track_info(b, hevc_video_tid(b))
      assert ISOMedia.serialize(b) == bin
    end
  end
```

- [ ] **Step 4: Run the integration tests to verify they pass**

Run: `mix test test/iso_media/codec_test.exs`
Expected: PASS. If the round-trip test fails, the fixture exercises a parser path unrelated to this change — STOP and report (do not edit the parser to accommodate the fixture).

- [ ] **Step 5: Run the full suite + gates**

Run: `mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: all tests pass, formatting clean, zero warnings.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/sample_hevc.mp4 test/iso_media/codec_test.exs
git commit -m "test: HEVC fixture + integration (track_info, HLS/DASH unblock, round-trip)"
```

---

## Task 4: Documentation

**Files:**
- Modify: `lib/iso_media/codec.ex` (moduledoc)
- Modify: `CHANGELOG.md`
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: Update the Codec moduledoc**

In `lib/iso_media/codec.ex`, the moduledoc says `(avc1 + mp4a)`. Change it to `(avc1 + hvc1/hev1 + mp4a)`:

```elixir
  @moduledoc """
  Read-only extraction of a track's codec + media metadata into `%ISOMedia.TrackInfo{}`.
  Slices the opaque `stsd` sample entry and `mdhd` tail directly (avc1 + hvc1/hev1 + mp4a);
  the core parser/Registry are untouched, so the byte-for-byte round-trip invariant is preserved.
  """
```

- [ ] **Step 2: Add a CHANGELOG entry**

In `CHANGELOG.md`, under the `## [0.2.0]` section's most recent released state, add a new `## [Unreleased]` section at the top (right after the intro paragraph block, before `## [0.2.0]`):

```markdown
## [Unreleased]

### Added

- **HEVC codec metadata** — `track_info/2` now decodes `hvc1`/`hev1` video tracks, producing
  the RFC 6381 codec string (e.g. `hvc1.1.6.L93.B0`); HLS and DASH manifest generation work on
  HEVC content.

```

And add the link reference near the bottom, above the `[0.2.0]:` line:

```markdown
[Unreleased]: https://github.com/bradhanks/iso_media/compare/v0.2.0...HEAD
```

- [ ] **Step 3: Update the ROADMAP**

In `docs/ROADMAP.md`, HEVC is currently item #1 under "Next up" and listed under "Codec coverage". Mark it done: in the "Codec coverage" section, change the HEVC bullet to note it shipped, and in the "Next up" section, promote **ABR** to #1 and drop HEVC. Specifically, replace the HEVC line under "Codec coverage":

```markdown
- **HEVC** (`hvc1` / `hev1`) — `hvcC` config parse → `hvc1.*` RFC 6381 string. *Highest user
  value: unblocks modern web / Apple content.* Needs a fixture.
```

with:

```markdown
- ~~**HEVC** (`hvc1` / `hev1`)~~ — **shipped** (Unreleased): `hvcC` config parse →
  `hvc1.*`/`hev1.*` RFC 6381 string; `track_info/2` + HLS/DASH work on HEVC.
```

and in the "Next up (leading candidates)" section, remove the HEVC item (1) and renumber ABR to be the single leading candidate.

- [ ] **Step 4: Verify gates still pass**

Run: `mix test && mix format --check-formatted`
Expected: pass (docs-only changes; nothing should break).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/codec.ex CHANGELOG.md docs/ROADMAP.md
git commit -m "docs: record HEVC support (moduledoc, CHANGELOG, ROADMAP)"
```

---

## Notes for the implementer

- **Uppercase hex is free:** `Integer.to_string(255, 16)` returns `"FF"` in Elixir — no `.upcase`/`String.downcase` needed. (Contrast `mp4a_codec/1`, which deliberately downcases.)
- **Do not touch** `lib/iso_media/registry.ex` or the parser — `hvc1`/`hev1` must NOT become container box types; that would change parsing and risk the round-trip invariant. All HEVC logic lives in `codec.ex`, reading the opaque `stsd` slice.
- **Clause order matters:** the matching `hvc1`/`hev1` `parse_entry/3` clause (with `byte_size(entry) >= 86`) must come before the truncation clause.
