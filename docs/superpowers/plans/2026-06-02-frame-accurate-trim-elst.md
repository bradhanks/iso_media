# Frame-Accurate Trim (elst) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ISOMedia.trim/3` frame-accurate by adding a per-track edit list (`elst`) that hides the leading frames produced by snap-to-keyframe, so presentation begins exactly at the requested time.

**Architecture:** A new `ISOMedia.Boxes.EditList` typed view (decode/encode `elst`, v0/v1, handling the media-vs-movie timescale fields). `ISOMedia.Trim` computes each track's `lead` (requested start − snap keyframe dts, track timescale) and `visible` (kept media − lead), and when `lead > 0` inserts a fresh `edts`/`elst` after `tkhd` (dropping any inherited `edts`). Samples/`mdat`/durations are unchanged.

**Tech Stack:** Elixir 1.19 / OTP 29, ExUnit.

**Branch:** `feat/elst` (holds the approved spec at `docs/superpowers/specs/2026-06-02-frame-accurate-trim-elst-design.md`).

**Conventions:** end every commit message with:
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```
Keep the branch format-clean (`mix format`; a `style: mix format` commit is fine).

---

### Task 1: `ISOMedia.Boxes.EditList` typed view

**Files:**
- Create: `lib/iso_media/boxes/edit_list.ex`
- Test: `test/iso_media/boxes/edit_list_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/boxes/edit_list_test.exs`:

```elixir
defmodule ISOMedia.Boxes.EditListTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.EditList

  test "decodes a v0 elst" do
    # version 0, 1 entry: segment_duration 25, media_time 5, rate 1.0
    data = <<0, 0, 0, 0, 1::32, 25::32, 5::signed-32, 1::signed-16, 0::16>>
    el = EditList.decode(%Box{type: "elst", data: data})
    assert el.version == 0
    assert el.entries == [%{segment_duration: 25, media_time: 5, rate_integer: 1, rate_fraction: 0}]
  end

  test "decodes a v0 empty edit (media_time -1)" do
    data = <<0, 0, 0, 0, 1::32, 100::32, -1::signed-32, 1::signed-16, 0::16>>
    el = EditList.decode(%Box{type: "elst", data: data})
    assert hd(el.entries).media_time == -1
  end

  test "v0 round-trips (small values stay v0)" do
    box = %Box{type: "elst", data: <<0, 0, 0, 0, 1::32, 25::32, 5::signed-32, 1::signed-16, 0::16>>}
    assert EditList.encode(EditList.decode(box)) == box
  end

  test "encode upgrades to v1 when a value exceeds 32 bits" do
    el = %EditList{
      version: 0,
      entries: [%{segment_duration: 5_000_000_000, media_time: 0, rate_integer: 1, rate_fraction: 0}]
    }

    box = EditList.encode(el)
    assert <<1::8, 0::24, 1::32, 5_000_000_000::64, 0::signed-64, 1::signed-16, 0::16>> = box.data
    # and it round-trips back to the same struct (now v1)
    assert EditList.decode(box).entries == el.entries
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/boxes/edit_list_test.exs`
Expected: FAIL — `ISOMedia.Boxes.EditList.decode/1 is undefined`.

- [ ] **Step 3: Write the implementation**

Create `lib/iso_media/boxes/edit_list.ex`:

```elixir
defmodule ISOMedia.Boxes.EditList do
  @moduledoc """
  Typed view of the `elst` Edit List Box (inside `trak` → `edts`).

  Each entry is `%{segment_duration, media_time, rate_integer, rate_fraction}`.
  Timescales differ by field: `segment_duration` is in the **movie** timescale
  (`mvhd`), `media_time` is in the track's **media** timescale (`mdhd`). `media_time`
  is `-1` for an empty edit. Encoding uses version 0 unless a `segment_duration` or
  `media_time` needs 64 bits, in which case version 1.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :entries]

  @type entry :: %{
          segment_duration: non_neg_integer(),
          media_time: integer(),
          rate_integer: integer(),
          rate_fraction: non_neg_integer()
        }

  @type t :: %__MODULE__{version: 0 | 1, entries: [entry()]}

  @uint32_max 0xFFFFFFFF
  @int32_max 0x7FFFFFFF
  @int32_min -0x80000000

  @doc "Decode an `elst` box into a `%EditList{}`."
  def decode(%Box{type: "elst", data: data}) do
    {version, _flags, <<_count::32, rest::binary>>} = FullBox.parse(data)
    %__MODULE__{version: version, entries: decode_entries(version, rest)}
  end

  defp decode_entries(0, bin) do
    for <<seg::32, mt::signed-32, ri::signed-16, rf::16 <- bin>> do
      %{segment_duration: seg, media_time: mt, rate_integer: ri, rate_fraction: rf}
    end
  end

  defp decode_entries(1, bin) do
    for <<seg::64, mt::signed-64, ri::signed-16, rf::16 <- bin>> do
      %{segment_duration: seg, media_time: mt, rate_integer: ri, rate_fraction: rf}
    end
  end

  @doc "Encode a `%EditList{}` into an `elst` box (v0, or v1 if a value needs 64 bits)."
  def encode(%__MODULE__{entries: entries}) do
    version = if Enum.any?(entries, &needs_v1?/1), do: 1, else: 0
    body = [<<length(entries)::32>>, Enum.map(entries, &encode_entry(version, &1))]
    %Box{type: "elst", data: IO.iodata_to_binary(FullBox.encode(version, <<0, 0, 0>>, body))}
  end

  defp needs_v1?(%{segment_duration: seg, media_time: mt}) do
    seg > @uint32_max or mt > @int32_max or mt < @int32_min
  end

  defp encode_entry(0, %{segment_duration: seg, media_time: mt, rate_integer: ri, rate_fraction: rf}) do
    <<seg::32, mt::signed-32, ri::signed-16, rf::16>>
  end

  defp encode_entry(1, %{segment_duration: seg, media_time: mt, rate_integer: ri, rate_fraction: rf}) do
    <<seg::64, mt::signed-64, ri::signed-16, rf::16>>
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/boxes/edit_list_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/boxes/edit_list.ex test/iso_media/boxes/edit_list_test.exs
git commit -m "feat: typed view for elst (EditList)"
```

---

### Task 2: `Trim` emits the edit list

**Files:**
- Modify: `lib/iso_media/trim.ex`
- Test: `test/iso_media/trim_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/iso_media/trim_test.exs`:

```elixir
  test "trim adds a frame-accurate edit list (media_time = snap lead)" do
    # track 1 keyframes at samples 1 & 3 (dts 0 & 20), durations 10 → dts 0,10,20,30.
    {_bin, boxes} = build()
    # start 25 snaps back to keyframe sample 3 (dts 20): lead = 25 - 20 = 5.
    out = boxes |> ISOMedia.trim(25, 35) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    elst = ISOMedia.Box.find(reparsed, ~w(moov trak edts elst))
    el = ISOMedia.Boxes.EditList.decode(elst)
    # kept = samples 3,4 (durations 10 each) → visible = 20 - 5 = 15; timescales = 1.
    assert el.entries == [%{segment_duration: 15, media_time: 5, rate_integer: 1, rate_fraction: 0}]

    # samples are unchanged by the edit list
    s = ISOMedia.samples(reparsed, 1)
    assert Enum.map(s, &binary_part(out, &1.offset, &1.size)) == [<<3, 3>>, <<4, 4>>]
  end

  test "trim emits no edts when the start lands exactly on a keyframe" do
    {_bin, boxes} = build()
    # start 20 == keyframe sample 3's dts → lead 0 → no edit list.
    out = boxes |> ISOMedia.trim(20, 35) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)
    assert ISOMedia.Box.find(reparsed, ~w(moov trak edts)) == nil
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/iso_media/trim_test.exs`
Expected: FAIL — no `edts`/`elst` in the trimmed output.

- [ ] **Step 3: Record `lead`/`visible` in `select_track`**

In `lib/iso_media/trim.ex`, replace the final return map of `select_track/…` (the
`%{trak: trak, ts: ts, kept: kept, runs: Enum.chunk_by(kept, & &1.chunk_index)}` line)
with:

```elixir
    snap_dts = hd(kept).dts
    lead = max(0, start_ts - snap_dts)
    visible = Enum.sum(Enum.map(kept, & &1.duration)) - lead

    %{
      trak: trak,
      ts: ts,
      kept: kept,
      runs: Enum.chunk_by(kept, & &1.chunk_index),
      lead: lead,
      visible: visible
    }
```

(The `kept` list and `start_ts` are already in scope from the existing function body.)

- [ ] **Step 4: Insert the `edts`/`elst` in `build_trimmed_trak`**

In `lib/iso_media/trim.ex`, add `EditList` to the `Boxes` alias (the existing
`alias ISOMedia.Boxes.{ChunkOffset, MediaHeader, MovieHeader, TrackHeader}` becomes):

```elixir
  alias ISOMedia.Boxes.{ChunkOffset, EditList, MediaHeader, MovieHeader, TrackHeader}
```

Append a `put_edts` step to the end of `build_trimmed_trak/…`'s pipe — change its
final line:

```elixir
    |> update_descendant(["tkhd"], &set_tkhd_duration(&1, scale(track_dur, sel.ts, movie_ts)))
```

to:

```elixir
    |> update_descendant(["tkhd"], &set_tkhd_duration(&1, scale(track_dur, sel.ts, movie_ts)))
    |> put_edts(edts_for(sel, movie_ts))
```

Then add these private helpers (near the other `build_trimmed_trak` helpers):

```elixir
  # An `edts` box (containing one `elst`) for the track, or nil when there is no lead
  # to hide.
  defp edts_for(%{lead: lead} = sel, movie_ts) when lead > 0 do
    elst =
      EditList.encode(%EditList{
        version: 0,
        entries: [
          %{
            segment_duration: scale(sel.visible, sel.ts, movie_ts),
            media_time: lead,
            rate_integer: 1,
            rate_fraction: 0
          }
        ]
      })

    %Box{type: "edts", data: nil, children: [elst]}
  end

  defp edts_for(_sel, _movie_ts), do: nil

  # Drop any inherited `edts` (the timeline is re-based), then insert the fresh one
  # (if any) immediately after `tkhd`.
  defp put_edts(trak, edts) do
    children = Enum.reject(trak.children, &(&1.type == "edts"))

    children =
      if edts do
        idx = Enum.find_index(children, &(&1.type == "tkhd"))
        at = if idx, do: idx + 1, else: 0
        {pre, post} = Enum.split(children, at)
        pre ++ [edts] ++ post
      else
        children
      end

    %{trak | children: children}
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/iso_media/trim_test.exs`
Expected: PASS (the new edit-list tests + all existing trim tests — samples/durations are unchanged, so they still pass).

- [ ] **Step 6: Full suite + format + commit**

Run: `mix test && mix format && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: green, clean, no warnings. (`edts` is already a registered container in `ISOMedia.Registry`, so the synthesized `edts`/`elst` round-trips through parse/serialize.)

```bash
git add lib/iso_media/trim.ex test/iso_media/trim_test.exs
git commit -m "feat: trim emits a frame-accurate edit list (elst) per track"
```

---

### Task 3: Real-fixture `elst` test + docs

**Files:**
- Modify: `test/iso_media/trim_av_test.exs`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: Write the real-fixture test**

Add to `test/iso_media/trim_av_test.exs`:

```elixir
  test "trim adds a correct edit list to the real video track" do
    {:ok, boxes} = ISOMedia.read(@fixture)
    [vid | _] = ISOMedia.track_ids(boxes)

    # Compute the expected lead for the video track at start 0.5s, from the originals.
    moov = Enum.find(boxes, &(&1.type == "moov"))
    trak = Enum.find(moov.children, fn t ->
      t.type == "trak" and ISOMedia.Boxes.TrackHeader.decode(ISOMedia.Box.find([t], ~w(trak tkhd))).track_id == vid
    end)

    ts = ISOMedia.Boxes.MediaHeader.decode(ISOMedia.Box.find([trak], ~w(trak mdia mdhd))).timescale
    start_ts = round(0.5 * ts)
    samples = ISOMedia.samples(boxes, vid)
    snap_dts = samples |> Enum.filter(&(&1.sync? and &1.dts <= start_ts)) |> List.last() |> Map.get(:dts, 0)
    expected_lead = max(0, start_ts - snap_dts)

    out = boxes |> ISOMedia.trim(0.5, 0.9) |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    out_trak = Enum.find(Enum.find(reparsed, &(&1.type == "moov")).children, fn t ->
      t.type == "trak" and ISOMedia.Boxes.TrackHeader.decode(ISOMedia.Box.find([t], ~w(trak tkhd))).track_id == vid
    end)

    elst = ISOMedia.Box.find([out_trak], ~w(trak edts elst))
    assert elst != nil, "video track should have an edit list"
    [entry] = ISOMedia.Boxes.EditList.decode(elst).entries
    assert entry.media_time == expected_lead
    assert entry.rate_integer == 1
  end
```

- [ ] **Step 2: Run it**

Run: `mix test test/iso_media/trim_av_test.exs`
Expected: PASS. (If `media_time` mismatches, the lead math in `Trim.select_track` is wrong vs the real sample table — debug, do not weaken.)

- [ ] **Step 3: Update the README**

In `README.md`, in the "## Trim" section, replace the sentence:

```markdown
Frame-accurate start (an `elst` to hide the leading frames before the requested
point) and concatenation are future phases.
```

with:

```markdown
The result is **frame-accurate**: each track gets an edit list (`elst`) so playback
presents exactly from the requested start, even though the decoded media begins at
the preceding keyframe. Concatenation is a future phase.
```

- [ ] **Step 4: Update CLAUDE.md**

In `CLAUDE.md`, add to the `ISOMedia.Boxes.*` line (or as its own bullet) that
`EditList` (`elst`) is now a typed view, and note in the `ISOMedia.Trim` bullet that
trim emits a per-track `edts`/`elst` for frame-accurate presentation.

- [ ] **Step 5: Verify + commit**

Run: `mix test && mix compile --warnings-as-errors && mix format --check-formatted`
Expected: green, clean.

```bash
git add test/iso_media/trim_av_test.exs README.md CLAUDE.md
git commit -m "test: real-fixture edit-list assertion; docs for frame-accurate trim"
```

---

## Self-Review Notes

- **Spec coverage:** `EditList` decode/encode v0/v1 (T1); `Trim` records `lead`/`visible` and inserts `edts`/`elst` after `tkhd` when `lead > 0`, dropping inherited `edts` (T2); real-fixture `elst` assertion + docs (T3). Out-of-scope (empty edits, multiple edits, source-elst merge, rate≠1) excluded.
- **Type consistency:** `%EditList{version, entries}` with entry keys `segment_duration`/`media_time`/`rate_integer`/`rate_fraction` consistent across T1/T2/T3; `EditList.decode/encode` reused; `scale/3`, `select_track`, `build_trimmed_trak` are existing Trim functions extended in place.
- **Timescale correctness:** `media_time = lead` (track timescale, from `select_track`); `segment_duration = scale(visible, track_ts, movie_ts)` (movie timescale). Matches the spec's media-vs-movie split.
- **Non-regression:** samples/`mdat`/durations unchanged → Phase 5 byte-identity/interleave/lazy tests still pass; `edts` is a registered container so it round-trips.
- **Placeholders:** none — every code/test step is complete.
