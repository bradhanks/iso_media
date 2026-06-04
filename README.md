# ISOMedia

Lossless ISOBMFF (MP4 / MOV / M4A / HEIF) box surgery in pure Elixir.

Parse any ISO Base Media file into a tree of boxes — every box, including
unknown/vendor boxes, preserved byte-for-byte — then navigate, extract, reorder,
insert, edit, and re-serialize. The invariant throughout is
`ISOMedia.serialize(ISOMedia.parse(file)) == file`.

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

`write/2` returns `:ok` on success or `{:error, reason}` if the output file cannot be
opened; it may raise on a mid-stream I/O error (e.g. disk full).

## Sample-level access

Read a track's samples, or demux a single track into its own file:

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")
ISOMedia.track_ids(boxes)            # => [1, 2]
ISOMedia.samples(boxes, 1)           # => [%ISOMedia.Sample{dts:, pts:, size:, offset:, sync?:, ...}, ...]

# Extract just track 1 (rebuilds mdat + chunk offsets; streams the media disk→disk under lazy:)
ISOMedia.write("track1.mp4", ISOMedia.extract_track(boxes, 1))
```

`samples/2` works on both progressive and fragmented files (it dispatches to the
fragment indexer automatically). Extraction preserves the track's existing sample
tables and chunking; it rebuilds only `mdat` and `stco`/`co64`. Movie/track
`mvhd`/`tkhd` durations are left as-is. `stz2` sample sizes are not yet supported
(raises). For time-range trimming see **Trim**, for joining clips see
**Concatenate**, both below.

## Trim

Losslessly trim every track to a time range (no re-encode). The video start snaps
back to the nearest keyframe so the result decodes; the timeline re-bases to 0 and
A/V interleave is preserved:

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")
ISOMedia.write("clip.mp4", ISOMedia.trim(boxes, 10.0, 25.0))   # keep 10s..25s
```

`trim/3` rebuilds each track's sample tables and `mdat` and updates the duration
headers. The result is **frame-accurate**: each track gets an edit list (`elst`) so
playback presents exactly from the requested start, even though the decoded media
begins at the preceding keyframe.

## Concatenate

Join compatible clips end-to-end, losslessly:

```elixir
clips = Enum.map(["a.mp4", "b.mp4", "c.mp4"], fn p -> {:ok, b} = ISOMedia.read(p); b end)
ISOMedia.write("joined.mp4", ISOMedia.concat(clips))
```

Clips must be compatible: same track count, and per track a byte-identical `stsd`
(same codec/resolution/settings) and the same media timescale — otherwise it raises
(lossless concat can't reconcile different encodings). Source edit lists are ignored,
so concatenating clips that were previously **trimmed** will make their hidden
keyframe lead-in frames visible at each splice. Because each track's timeline is the
sum of its own sample durations, tracks whose raw media durations differ slightly
(e.g. audio a little longer than video) can accumulate **minor A/V drift across many
splices** — expected for a lossless sample-level join without edit-list reconciliation.

## Fragment ⇆ defragment (fMP4)

Convert between progressive MP4 and **fragmented** MP4 (the `moof`/`traf`/`trun`
container behind DASH / HLS / CMAF), losslessly and memory-safely:

```elixir
{:ok, boxes} = ISOMedia.read("movie.mp4")

# progressive -> fragmented: keyframe-aligned ~2s fragments (multiplexed single file)
frag = ISOMedia.fragment(boxes, target_duration: 2.0)
ISOMedia.write("movie.frag.mp4", frag)

# fragmented -> progressive (single moov + mdat)
{:ok, frag_boxes} = ISOMedia.read("movie.frag.mp4")
ISOMedia.write("movie.prog.mp4", ISOMedia.defragment(frag_boxes))
```

`fragment/2` reads each track's samples, picks fragment boundaries from the first
video track's keyframes snapped to `target_duration` (default `2.0` seconds; a
fragment can only start on a keyframe, so it can't be finer than the keyframe
spacing), and emits `[ftyp, moov(+mvex), moof, mdat, …]` with the media referenced
from the source (no copy). `defragment/1` collapses the fragments back into one
`moov` + `mdat`. The two are inverses: `defragment(fragment(x))` reproduces every
sample's timing and bytes. Separate DASH/CMAF init + media segments and manifest
(MPD / playlist) generation are out of scope. Encrypted (CENC) fragments raise.

## In-memory pipelines

`trim`, `extract_track`, `concat`, `fragment`, and `defragment` all return a box
tree whose `mdat` references the source bytes (a lazy segment list), and they can
read from each other's output — so you can chain operations **without writing
intermediates to disk**:

```elixir
{:ok, a} = ISOMedia.read("a.mp4")
{:ok, b} = ISOMedia.read("b.mp4")

a
|> ISOMedia.trim(0.0, 30.0)
|> then(&ISOMedia.concat([&1, b]))
|> ISOMedia.fragment(target_duration: 4.0)
|> then(&ISOMedia.write("out.frag.mp4", &1))
```

The bytes are identical to running the same stages with a write+re-read between each,
and memory stays at metadata + one stream chunk under `lazy:`. The one exception is
offset rewriting: `faststart/1` and `fix_chunk_offsets/1` operate on an original,
parsed `mdat` and **raise on a synthesized (chained) `mdat`** — run faststart on the
source before editing, or write the result to disk and read it back.

## Status

Implemented, all lossless and verified byte-for-byte against real fixtures:

- **Tree surgery** — parse → navigate/edit/reorder/insert → re-serialize, byte-exact.
- **faststart** — `moov` to the front with `stco`/`co64` rewriting (`stco`→`co64`
  auto-promotion).
- **Lazy payloads** — process files larger than RAM (stream `mdat` disk→disk).
- **Sample index + extraction** — flat `[%Sample{}]` per track; demux one track.
- **Trim** — time-range, keyframe-aligned, frame-accurate (`elst`), interleave-preserving.
- **Concatenate** — join compatible clips end-to-end.
- **Recursive virtual I/O** — chain the above in memory, no disk round-trip.
- **Fragmented MP4** — index/`defragment` fMP4, and `fragment` progressive → fMP4.

Out of scope (for now): re-encoding, DASH/HLS manifest and separate-segment
generation, encrypted (CENC) fMP4, `stz2` compact sample sizes, and HEIF/AVIF `iloc`
image editing. See `docs/superpowers/specs/` for the per-phase designs.
