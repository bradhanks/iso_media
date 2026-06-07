# HLS Playlist Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate HLS VOD playlists for the CMAF segments — `ISOMedia.hls_media_playlist/2` (segment list), `ISOMedia.hls_master_playlist/2` (codecs/resolution/bandwidth), and `ISOMedia.write_hls/3` (the bundle).

**Architecture:** A shared `FragmentIndex.fragment_spans/1` computes per-`moof` `{duration_ts, timescale, bytes}` (reusing the existing cascade). `ISOMedia.HLS` is pure string templating over those spans + `%TrackInfo{}` (codecs/resolution) + `write_segments` URIs. Correctness is byte-exact playlist strings pinned to the real fixture.

**Tech Stack:** Elixir, ExUnit. Reuses Phase 9 `FragmentIndex`, Phase 11 `write_segments`, Phase 12 `track_info`, and the `sample_keyint.mp4` fixture. No new deps.

---

## File structure

**Modified:**
- `lib/iso_media/fragment_index.ex` — add public `fragment_spans/1` + small helpers
- `lib/iso_media.ex` — `hls_media_playlist/2`, `hls_master_playlist/2`, `write_hls/3` delegators
- `CLAUDE.md` — architecture bullet

**Created:**
- `lib/iso_media/hls.ex` — `media_playlist/2`, `master_playlist/2`, `write_hls/3`
- `test/iso_media/fragment_index_spans_test.exs` — `fragment_spans/1`
- `test/iso_media/hls_test.exs` — byte-exact playlists + bundle

Pinned fixture values (`fragment(read("sample_keyint.mp4"), target_duration: 0.5)`): 2 segments;
`fragment_spans` = `[%{duration_ts: 10240, timescale: 10240, bytes: 12049}, %{duration_ts: 10240, timescale: 10240, bytes: 11096}]`; both `EXTINF:1.000`; `TARGETDURATION:1`; `BANDWIDTH=96392`; `CODECS="avc1.64000a,mp4a.40.2"`; `RESOLUTION=128x96`.

---

## Task 1: `FragmentIndex.fragment_spans/1` (shared per-moof spans)

**Files:**
- Modify: `lib/iso_media/fragment_index.ex`
- Test: `test/iso_media/fragment_index_spans_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/fragment_index_spans_test.exs`:

```elixir
defmodule ISOMedia.FragmentIndexSpansTest do
  use ExUnit.Case

  test "fragment_spans returns per-moof duration_ts/timescale/bytes (video-preferred traf)" do
    {:ok, b} = ISOMedia.read("test/fixtures/sample_keyint.mp4")
    f = ISOMedia.fragment(b, target_duration: 0.5)

    assert ISOMedia.FragmentIndex.fragment_spans(f) == [
             %{duration_ts: 10240, timescale: 10240, bytes: 12049},
             %{duration_ts: 10240, timescale: 10240, bytes: 11096}
           ]
  end

  test "fragment_spans count equals the moof count" do
    {:ok, b} = ISOMedia.read("test/fixtures/sample_keyint.mp4")
    f = ISOMedia.fragment(b, target_duration: 0.5)
    assert length(ISOMedia.FragmentIndex.fragment_spans(f)) ==
             Enum.count(f, &(&1.type == "moof"))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/fragment_index_spans_test.exs`
Expected: FAIL — `FragmentIndex.fragment_spans/1` undefined.

- [ ] **Step 3: Implement `fragment_spans/1` + helpers**

In `lib/iso_media/fragment_index.ex`, widen the alias lines to add the modules used here:

```elixir
  alias ISOMedia.{Box, BoxPath, Extract, Layout, Sample}

  alias ISOMedia.Boxes.{
    Handler,
    MediaHeader,
    TrackExtends,
    TrackFragmentDecodeTime,
    TrackFragmentHeader,
    TrackHeader,
    TrackRun
  }
```

Then add (after `samples/2`, keeping the existing private helpers below it intact):

```elixir
  @doc """
  Per-`moof` spans for the fragmented tree `boxes`, in tree order:
  `[%{duration_ts, timescale, bytes}]`. For each `moof` the video `traf` is preferred (else
  the first `traf`); its `trun` sample durations are summed (via the cascade) for
  `duration_ts`, `timescale` is that track's `mdhd` timescale, and `bytes` is the sibling
  `mdat`'s payload size. Shared by HLS/DASH manifest generation.
  """
  @spec fragment_spans([Box.t()]) :: [%{duration_ts: non_neg_integer(), timescale: pos_integer(), bytes: non_neg_integer()}]
  def fragment_spans(boxes) do
    video_tid = video_track_id(boxes)
    moofs = Enum.filter(boxes, &(&1.type == "moof"))
    mdats = Enum.filter(boxes, &(&1.type == "mdat"))

    moofs
    |> Enum.zip(mdats)
    |> Enum.map(fn {moof, mdat} ->
      traf = (video_tid && traf_for(moof, video_tid)) || first_traf(moof)
      tfhd = TrackFragmentHeader.decode(child!(traf, "tfhd"))
      defaults = defaults(tfhd, trex_for!(boxes, tfhd.track_id))

      duration_ts =
        traf.children
        |> Enum.filter(&(&1.type == "trun"))
        |> Enum.flat_map(fn t -> resolve_run(TrackRun.decode(t), defaults) end)
        |> Enum.map(& &1.duration)
        |> Enum.sum()

      %{
        duration_ts: duration_ts,
        timescale: track_timescale(boxes, tfhd.track_id),
        bytes: Layout.box_size(mdat) - Layout.header_size(mdat)
      }
    end)
  end

  defp first_traf(moof), do: Enum.find(moof.children, &(&1.type == "traf"))

  defp video_track_id(boxes) do
    moov = Enum.find(boxes, &(&1.type == "moov"))

    moov.children
    |> Enum.filter(&(&1.type == "trak"))
    |> Enum.find_value(fn trak ->
      if Handler.decode(BoxPath.dig(trak, ~w(mdia hdlr))).handler_type == "vide" do
        TrackHeader.decode(BoxPath.dig(trak, ["tkhd"])).track_id
      end
    end)
  end

  defp track_timescale(boxes, track_id) do
    trak = Extract.find_trak(boxes, track_id)
    MediaHeader.decode(BoxPath.dig(trak, ~w(mdia mdhd))).timescale
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/fragment_index_spans_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/fragment_index.ex test/iso_media/fragment_index_spans_test.exs
git commit -m "feat: FragmentIndex.fragment_spans/1 (per-moof duration/bytes for manifests)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `HLS.media_playlist/2` + delegator

**Files:**
- Create: `lib/iso_media/hls.ex`
- Modify: `lib/iso_media.ex`
- Test: `test/iso_media/hls_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/iso_media/hls_test.exs`:

```elixir
defmodule ISOMedia.HLSTest do
  use ExUnit.Case

  defp fragged do
    {:ok, b} = ISOMedia.read("test/fixtures/sample_keyint.mp4")
    ISOMedia.fragment(b, target_duration: 0.5)
  end

  test "media_playlist is the byte-exact VOD playlist" do
    expected = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-TARGETDURATION:1
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:1.000,
    seg-1.m4s
    #EXTINF:1.000,
    seg-2.m4s
    #EXT-X-ENDLIST
    """

    assert ISOMedia.hls_media_playlist(fragged()) == expected
  end

  test "raises on progressive (non-fragmented) input" do
    {:ok, prog} = ISOMedia.read("test/fixtures/sample_av.mp4")
    assert_raise ArgumentError, fn -> ISOMedia.hls_media_playlist(prog) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/hls_test.exs`
Expected: FAIL — `ISOMedia.hls_media_playlist/1` undefined.

- [ ] **Step 3: Create `ISOMedia.HLS` + the delegator**

Create `lib/iso_media/hls.ex`:

```elixir
defmodule ISOMedia.HLS do
  @moduledoc """
  Generate HLS (`.m3u8`) playlists for the CMAF segments `ISOMedia.split_segments/1`
  produces — a media playlist (segment list) and a multivariant (master) playlist
  (codecs/resolution/bandwidth), for a single muxed VOD rendition. Pure string templating
  over `FragmentIndex.fragment_spans/1` + `ISOMedia.track_info/2`; URIs match `write_segments`.
  """
  alias ISOMedia.FragmentIndex

  @doc "The HLS media playlist (`.m3u8`) for a fragmented tree. See module opts."
  @spec media_playlist([ISOMedia.Box.t()], keyword()) :: String.t()
  def media_playlist(boxes, opts \\ []) do
    validate!(boxes)
    init_name = Keyword.get(opts, :init_name, "init.mp4")
    pattern = Keyword.get(opts, :segment_pattern, fn i -> "seg-#{i}.m4s" end)
    spans = FragmentIndex.fragment_spans(boxes)
    target = spans |> Enum.map(&seconds/1) |> Enum.max() |> Float.ceil() |> trunc()

    segment_lines =
      spans
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {s, i} ->
        ["#EXTINF:#{:erlang.float_to_binary(seconds(s), decimals: 3)},", pattern.(i)]
      end)

    lines =
      [
        "#EXTM3U",
        "#EXT-X-VERSION:7",
        "#EXT-X-PLAYLIST-TYPE:VOD",
        "#EXT-X-TARGETDURATION:#{target}",
        ~s(#EXT-X-MAP:URI="#{init_name}")
      ] ++ segment_lines ++ ["#EXT-X-ENDLIST"]

    Enum.join(lines, "\n") <> "\n"
  end

  defp seconds(%{duration_ts: d, timescale: ts}), do: d / ts

  defp validate!(boxes) do
    unless FragmentIndex.fragmented?(boxes) do
      raise ArgumentError, "hls: expected a fragmented (fragment/2) tree"
    end
  end
end
```

In `lib/iso_media.ex`, add after the `write_segments/3` delegator:

```elixir
  @doc "Generate the HLS media playlist (`.m3u8`) for a fragmented tree. See `ISOMedia.HLS.media_playlist/2`."
  @spec hls_media_playlist(tree(), keyword()) :: String.t()
  def hls_media_playlist(boxes, opts \\ []), do: ISOMedia.HLS.media_playlist(boxes, opts)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/hls_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/hls.ex lib/iso_media.ex test/iso_media/hls_test.exs
git commit -m "feat: ISOMedia.hls_media_playlist/2 (HLS VOD media playlist)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `HLS.master_playlist/2` + delegator

**Files:**
- Modify: `lib/iso_media/hls.ex`, `lib/iso_media.ex`
- Test: `test/iso_media/hls_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/iso_media/hls_test.exs`:

```elixir
  test "master_playlist is the byte-exact multivariant playlist" do
    expected = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=96392,CODECS="avc1.64000a,mp4a.40.2",RESOLUTION=128x96
    media.m3u8
    """

    assert ISOMedia.hls_master_playlist(fragged()) == expected
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/hls_test.exs`
Expected: FAIL — `ISOMedia.hls_master_playlist/1` undefined.

- [ ] **Step 3: Add `master_playlist/2` + helpers + delegator**

In `lib/iso_media/hls.ex`, add `master_playlist/2` and its private helpers (after `media_playlist/2`):

```elixir
  @doc "The HLS multivariant (master) playlist (`.m3u8`) for a fragmented tree."
  @spec master_playlist([ISOMedia.Box.t()], keyword()) :: String.t()
  def master_playlist(boxes, opts \\ []) do
    validate!(boxes)
    media_uri = Keyword.get(opts, :media_uri, "media.m3u8")

    attrs =
      ["BANDWIDTH=#{peak_bandwidth(boxes)}", ~s(CODECS="#{track_codecs(boxes)}")] ++
        case resolution(boxes) do
          nil -> []
          res -> ["RESOLUTION=#{res}"]
        end

    Enum.join(["#EXTM3U", "#EXT-X-STREAM-INF:#{Enum.join(attrs, ",")}", media_uri], "\n") <> "\n"
  end

  defp track_infos(boxes) do
    boxes
    |> ISOMedia.track_ids()
    |> Enum.map(&ISOMedia.track_info(boxes, &1))
    |> Enum.sort_by(fn ti -> if ti.type == :video, do: 0, else: 1 end)
  end

  defp track_codecs(boxes), do: track_infos(boxes) |> Enum.map(& &1.codec) |> Enum.join(",")

  defp resolution(boxes) do
    case Enum.find(track_infos(boxes), &(&1.type == :video)) do
      nil -> nil
      ti -> "#{ti.width}x#{ti.height}"
    end
  end

  # Peak per-segment bit rate (bits/sec), integer ceil — HLS BANDWIDTH is the peak segment rate.
  defp peak_bandwidth(boxes) do
    FragmentIndex.fragment_spans(boxes)
    |> Enum.map(fn s -> div(s.bytes * 8 * s.timescale + s.duration_ts - 1, s.duration_ts) end)
    |> Enum.max()
  end
```

In `lib/iso_media.ex`, add after the `hls_media_playlist/2` delegator:

```elixir
  @doc "Generate the HLS multivariant playlist (`.m3u8`) for a fragmented tree. See `ISOMedia.HLS.master_playlist/2`."
  @spec hls_master_playlist(tree(), keyword()) :: String.t()
  def hls_master_playlist(boxes, opts \\ []), do: ISOMedia.HLS.master_playlist(boxes, opts)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/iso_media/hls_test.exs && mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/iso_media/hls.ex lib/iso_media.ex test/iso_media/hls_test.exs
git commit -m "feat: ISOMedia.hls_master_playlist/2 (codecs/resolution/peak bandwidth)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `HLS.write_hls/3` + bundle/audio-only/opts tests + docs

**Files:**
- Modify: `lib/iso_media/hls.ex`, `lib/iso_media.ex`, `CLAUDE.md`
- Test: `test/iso_media/hls_test.exs`

- [ ] **Step 1: Write the failing test**

Append inside the module in `test/iso_media/hls_test.exs`:

```elixir
  describe "write_hls/3 and edge cases" do
    setup do
      dir = Path.join(System.tmp_dir!(), "iso_hls_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "writes master + media + init + segments; all referenced files exist", %{dir: dir} do
      frag = fragged()
      n = Enum.count(frag, &(&1.type == "moof"))

      assert {:ok, paths} = ISOMedia.write_hls(dir, frag)
      assert paths == [
               Path.join(dir, "master.m3u8"),
               Path.join(dir, "media.m3u8"),
               Path.join(dir, "init.mp4")
               | Enum.map(1..n, &Path.join(dir, "seg-#{&1}.m4s"))
             ]

      assert Enum.all?(paths, &File.exists?/1)
      assert File.read!(Path.join(dir, "master.m3u8")) =~ "media.m3u8"
      media = File.read!(Path.join(dir, "media.m3u8"))
      assert media =~ ~s(URI="init.mp4")
      assert media =~ "seg-1.m4s"
    end

    test "audio-only: master has the audio codec and no RESOLUTION" do
      {:ok, b} = ISOMedia.read("test/fixtures/sample.m4a")
      frag = ISOMedia.fragment(b, target_duration: 0.3)
      master = ISOMedia.hls_master_playlist(frag)

      assert master =~ ~s(CODECS="mp4a.40.2")
      refute master =~ "RESOLUTION="
      assert ISOMedia.hls_media_playlist(frag) =~ "#EXT-X-ENDLIST"
    end

    test "custom opts flow through to playlists and filenames", %{dir: dir} do
      frag = fragged()

      assert {:ok, _} =
               ISOMedia.write_hls(dir, frag,
                 media_uri: "v.m3u8",
                 segment_pattern: fn i -> "c#{i}.m4s" end
               )

      assert File.exists?(Path.join(dir, "v.m3u8"))
      assert File.exists?(Path.join(dir, "c1.m4s"))
      assert File.read!(Path.join(dir, "master.m3u8")) =~ "v.m3u8"
      assert File.read!(Path.join(dir, "v.m3u8")) =~ "c1.m4s"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/iso_media/hls_test.exs`
Expected: FAIL — `ISOMedia.write_hls/3` undefined.

- [ ] **Step 3: Add `write_hls/3` + delegator**

In `lib/iso_media/hls.ex`, add (after `master_playlist/2`):

```elixir
  @doc """
  Write the HLS bundle into `dir` (created if absent): `master.m3u8`, the media playlist
  (`opts[:media_uri]`, default `media.m3u8`), and — via `ISOMedia.write_segments/3` — `init.mp4`
  + `seg-N.m4s`. Returns `{:ok, [master, media | segment_paths]}`.
  """
  @spec write_hls(Path.t(), [ISOMedia.Box.t()], keyword()) :: {:ok, [Path.t()]}
  def write_hls(dir, boxes, opts \\ []) do
    File.mkdir_p!(dir)
    master_path = Path.join(dir, "master.m3u8")
    media_path = Path.join(dir, Keyword.get(opts, :media_uri, "media.m3u8"))

    File.write!(master_path, master_playlist(boxes, opts))
    File.write!(media_path, media_playlist(boxes, opts))
    {:ok, segment_paths} = ISOMedia.write_segments(dir, boxes, opts)
    {:ok, [master_path, media_path | segment_paths]}
  end
```

In `lib/iso_media.ex`, add after the `hls_master_playlist/2` delegator:

```elixir
  @doc "Write a full HLS bundle (playlists + segments) into `dir`. See `ISOMedia.HLS.write_hls/3`."
  @spec write_hls(Path.t(), tree(), keyword()) :: {:ok, [Path.t()]}
  def write_hls(dir, boxes, opts \\ []), do: ISOMedia.HLS.write_hls(dir, boxes, opts)
```

- [ ] **Step 4: Run test + full sweep**

Run: `mix test test/iso_media/hls_test.exs && mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: HLS tests pass; full suite 0 failures; format clean; no warnings.

- [ ] **Step 5: Update CLAUDE.md and commit**

In `CLAUDE.md`, add an `ISOMedia.HLS` bullet (near `Segment`/`Fragment`): `ISOMedia.HLS` — `media_playlist/2`/`master_playlist/2` generate HLS VOD `.m3u8` strings for the CMAF segments (per-segment `EXTINF` durations + peak `BANDWIDTH` from `FragmentIndex.fragment_spans/1`; `CODECS`/`RESOLUTION` from `track_info/2`), `write_hls/3` writes the bundle (`master.m3u8` + `media.m3u8` + `write_segments` files). Exposed as `ISOMedia.hls_media_playlist/2`, `hls_master_playlist/2`, `write_hls/3`. Also note `FragmentIndex.fragment_spans/1` (shared per-`moof` duration/bytes).

```bash
git add lib/iso_media/hls.ex lib/iso_media.ex test/iso_media/hls_test.exs CLAUDE.md
git commit -m "feat: ISOMedia.write_hls/3 (full HLS bundle) + audio-only/opts coverage; docs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Full guarantee sweep**

Run: `mix test && mix format --check-formatted && mix compile --force --warnings-as-errors`
Expected: 0 failures, format clean, no warnings.

---

## Spec coverage check

- `FragmentIndex.fragment_spans/1` shared helper (per-moof duration/timescale/bytes, video-preferred) → Task 1.
- `media_playlist/2` (EXTINF, TARGETDURATION, EXT-X-MAP, ENDLIST, byte-exact) → Task 2.
- `master_playlist/2` (BANDWIDTH peak, CODECS joined, RESOLUTION) → Task 3.
- `write_hls/3` bundle (mkdir_p, master+media+segments, paths) → Task 4.
- Raises on non-fragmented input → Task 2.
- Audio-only (no RESOLUTION) + custom opts → Task 4.
- Delegators `hls_media_playlist/2`, `hls_master_playlist/2`, `write_hls/3` → Tasks 2-4.
- Deferred (DASH, ABR, demuxed/EXT-X-MEDIA, live, encryption) → not implemented, by design.
```
