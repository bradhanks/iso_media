defmodule ISOMedia.Extract do
  @moduledoc """
  Track discovery and single-track extraction.

  `track_ids/1` and `find_trak/2` locate tracks by their `tkhd` track_id;
  `extract_track/2` (added later) produces a new single-track tree.
  """

  alias ISOMedia.{Box, BoxPath, Layout, MdatSource, SampleTable}
  alias ISOMedia.Boxes.{ChunkOffset, TrackHeader}

  @uint32_max 0xFFFFFFFF

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
    case Box.child(boxes, "moov") do
      nil -> []
      moov -> Box.children(moov.children, "trak")
    end
  end

  defp track_id_of(%Box{} = trak) do
    tkhd = Box.find([trak], ~w(trak tkhd)) || raise ArgumentError, "trak is missing tkhd"
    TrackHeader.decode(tkhd).track_id
  end

  @doc """
  Return a new box tree containing only the track `track_id`, with `mdat` rebuilt as a
  segment list of that track's chunks and `stco`/`co64` recomputed. Memory-safe: with a
  lazy source the segments are `FileSlice`s streamed on `write/2`.
  """
  def extract_track(boxes, track_id) do
    trak = find_trak(boxes, track_id) || raise ArgumentError, "no track with track_id #{track_id}"
    ftyp = Box.child(boxes, "ftyp") || raise ArgumentError, "file has no ftyp"
    mdats = MdatSource.collect(boxes)

    runs =
      trak
      |> SampleTable.build()
      |> Enum.chunk_by(& &1.chunk_index)
      |> Enum.map(fn chunk_samples ->
        {hd(chunk_samples).offset, Enum.sum(Enum.map(chunk_samples, & &1.size))}
      end)

    segments = Enum.map(runs, fn {off, len} -> MdatSource.segment(mdats, off, len) end)
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
    mdat_mode = Box.size_mode_for_body(total)
    mdat_header = Box.header_base(mdat_mode)

    # Size moov with dummy offsets of the chosen kind, then place real offsets.
    moov0 = rebuild_moov(boxes, trak, offset_box(co_kind, zeros))
    mdat_payload_start = Layout.box_size(ftyp) + Layout.box_size(moov0) + mdat_header

    {chunk_offsets, _} =
      Enum.map_reduce(run_lengths, mdat_payload_start, fn len, pos -> {pos, pos + len} end)

    moov = rebuild_moov(boxes, trak, offset_box(co_kind, chunk_offsets))
    mdat = MdatSource.synthesized_mdat(segments, mdat_mode, mdat_payload_start)
    [ftyp, moov, mdat]
  end

  # --- helpers ---

  defp offset_box(kind, offsets) do
    ChunkOffset.encode(%ChunkOffset{kind: kind, version: 0, flags: <<0, 0, 0>>, offsets: offsets})
  end

  defp rebuild_moov(boxes, trak, new_offset_box) do
    moov = Box.child(boxes, "moov")
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
    BoxPath.update_descendant(trak, ~w(mdia minf stbl), fn stbl ->
      children =
        Enum.map(stbl.children, fn
          %Box{type: t} when t in ["stco", "co64"] -> new_box
          other -> other
        end)

      %{stbl | children: children}
    end)
  end
end
